#!/bin/bash

set -euo pipefail

# Get the directory where this script is actually located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Source the common functions from the same directory as this script
source "${SCRIPT_DIR}/bamp-common"



chmod o+x "$HOME"
mkdir -p "$HOME/www"
chmod -R o+rX "$HOME/www"


# Script-specific configuration
readonly SCRIPT_NAME="BAMP"

: "${WEBROOT:=$HOME/www}"

# Global variables
TARGET_PHP=""

show_usage() {
    cat <<EOF
Usage: bamp [OPTIONS] [PHP_VERSION]

Install and configure a local development environment with Apache, MySQL, and PHP.

OPTIONS:
    -h, --help          Show this help message
    -l, --list          List available PHP versions
    -s, --status        Show service status
    -r, --restart       Restart all services
    --stop              Stop all services
    --composer-check    Check Composer PHP version alignment
    --create-aliases    Create PHP version aliases for easy switching
    --uninstall         Uninstall all components (use with caution)
    --dry-run           Show what would be done without making changes

PHP_VERSION:
    Specify PHP version to use (e.g., 8.3, 8.2)
    Default: ${DEFAULT_PHP}

Examples:
    bamp                     # Install with default PHP ${DEFAULT_PHP}
    bamp 8.4                 # Install and switch to PHP 8.4
    bamp --status            # Show current service status
    bamp --composer-check    # Check Composer PHP version alignment
    bamp --create-aliases    # Create PHP version aliases
    bamp --restart           # Restart all services
    bamp --dry-run           # Preview installation steps

EOF
}

ensure_webroot() {
    # Create webroot and a basic index/info if missing
    create_dir_if_not_exists "$WEBROOT"

    # Minimal index to prove DocumentRoot switch worked (idempotent)
    local index_file="${WEBROOT}/index.php"
    if [[ ! -f "$index_file" ]]; then
        cat >"$index_file" <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>BAMP</title></head>
<body><h1>BAMP is live</h1><p>DocumentRoot: ${WEBROOT}</p></body></html>
EOF
    fi
}

configure_document_root() {
    # Point Apache DocumentRoot and matching <Directory> to $WEBROOT
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would set Apache DocumentRoot to: $WEBROOT"
        return 0
    fi
    if [[ ! -f "$HTTPD_CONF" ]]; then
        log_error "Apache configuration not found at: $HTTPD_CONF"
        return 1
    fi

    backup_file "$HTTPD_CONF"

    # Normalize paths for sed
    local escaped_webroot="${WEBROOT//\//\\/}"

    # Update DocumentRoot
    if grep -qE '^DocumentRoot ' "$HTTPD_CONF"; then
        sed -i.tmp "s|^DocumentRoot \".*\"|DocumentRoot \"${escaped_webroot}\"|g" "$HTTPD_CONF"
    else
        # Insert if missing, near the top-level config
        sed -i.tmp "1i DocumentRoot \"${escaped_webroot}\"" "$HTTPD_CONF"
    fi

    # Update the first <Directory "..."> that matches previous DocumentRoot OR create a dedicated one
    # Strategy: if a <Directory "..."> exists for /opt/homebrew/var/www or /usr/local/var/www, retarget it
    # if grep -qE '^<Directory "/(opt|usr)/local/?homebrew?/var/www">' "$HTTPD_CONF"; then
    #     sed -i.tmp "s|^<Directory \"/\(opt\|usr\)\/local\/\?homebrew\?\/var\/www\">|<Directory \"${escaped_webroot}\">|g" "$HTTPD_CONF"
    # fi
    if ! grep -qE "^<Directory \"${escaped_webroot}\">" "$HTTPD_CONF"; then
        cat >>"$HTTPD_CONF" <<EOF
        # BAMP: primary webroot
        <Directory "${WEBROOT}">
            Options Indexes FollowSymLinks
            AllowOverride All
            Require all granted
        </Directory>
EOF
    fi

    # Ensure DirectoryIndex contains index.php
    if grep -q "^DirectoryIndex" "$HTTPD_CONF"; then
        sed -i.tmp 's|^DirectoryIndex .*|DirectoryIndex index.php index.html|g' "$HTTPD_CONF"
    else
        echo "DirectoryIndex index.php index.html" >>"$HTTPD_CONF"
    fi

    rm -f "${HTTPD_CONF}.tmp"

    # Validate and restart Apache
    if ! apache_config_test; then
        log_error "Apache configuration test failed after DocumentRoot change"
        return 1
    fi
    if ! restart_service httpd; then
        log_error "Failed to restart Apache after DocumentRoot change"
        return 1
    fi

    log_success "Apache DocumentRoot set to ${WEBROOT}"
}

generate_blowfish_secret() {
    # 32 chars [a-zA-Z0-9] (phpMyAdmin requires a secret)
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
    else
        # Portable fallback
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
    fi
}

install_phpmyadmin() {
    # Install phpMyAdmin into $WEBROOT/phpmyadmin using Composer (idempotent).
    local pma_dir="${WEBROOT}/phpmyadmin"
    local pma_config="${pma_dir}/config.inc.php"
    local pma_sample="${pma_dir}/config.sample.inc.php"

    if [[ -d "$pma_dir" ]]; then
        log_info "phpMyAdmin already present at ${pma_dir}"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would install phpMyAdmin into ${pma_dir} via Composer"
        return 0
    fi

    if ! command_exists composer; then
        log_info "Composer not found; installing Composer first"
        install_composer || {
            log_error "Composer installation failed; cannot install phpMyAdmin"
            return 1
        }
    fi

    log_info "Installing phpMyAdmin (stable) into ${pma_dir} ..."
    if ! composer create-project --no-dev --prefer-dist phpmyadmin/phpmyadmin "${pma_dir}"; then
        log_error "composer create-project phpmyadmin/phpmyadmin failed"
        return 1
    fi

    if [[ -f "$pma_sample" && ! -f "$pma_config" ]]; then
        cp "$pma_sample" "$pma_config"
        local secret
        secret="$(generate_blowfish_secret)"
        perl -0777 -pe "s/\\\$cfg\\['blowfish_secret'\\]\\s*=\\s*'';/\\\$cfg['blowfish_secret'] = '${secret}';/g" -i "$pma_config"
        log_info "Configured phpMyAdmin blowfish secret"
    fi

    mkdir -p "${pma_dir}/tmp"
    chmod 700 "${pma_dir}/tmp" || true

    log_success "phpMyAdmin installed at ${pma_dir}"

    local base="http://localhost"
    [[ "${HTTP_PORT}" != "80" ]] && base="${base}:${HTTP_PORT}"
    log_info "URL: ${base}/phpmyadmin"
}


configure_phpmyadmin_apache_alias() {
    # Optional: only if you DID NOT install into $WEBROOT/phpmyadmin.
    # If you keep phpMyAdmin elsewhere, expose it as /phpmyadmin.
    local pma_path="$1"
    [[ -z "$pma_path" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create Apache Alias for /phpmyadmin -> ${pma_path}"
        return 0
    fi
    backup_file "$HTTPD_CONF"

    local escaped="${pma_path//\//\\/}"
    if ! grep -qE "^\s*Alias\s+/phpmyadmin\s+\"${escaped}\"" "$HTTPD_CONF"; then
        cat >>"$HTTPD_CONF" <<EOF

# BAMP: phpMyAdmin Alias
Alias /phpmyadmin "${pma_path}"
<Directory "${pma_path}">
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF
    fi

    if ! apache_config_test; then
        log_error "Apache configuration test failed after phpMyAdmin alias"
        return 1
    fi
    restart_service httpd || {
        log_error "Failed to restart Apache after phpMyAdmin alias"
        return 1
    }
    log_success "phpMyAdmin Alias configured"
}

list_php_versions() {
    log_info "Available PHP versions:"

    # Get current active PHP version from Apache config
    local current_php=$(get_current_php_version)

    for version in "${PHP_VERSIONS[@]}"; do
        local status_marker="⭕"
        local status_text="not installed"

        if brew_package_installed "php@${version}"; then
            status_marker="${CHECKMARK}"
            status_text="installed"

            if [[ "$version" == "$current_php" ]]; then
                status_text="installed, active in Apache"
                status_marker="${ROCKET}"
            fi
        fi

        echo "  $status_marker php@${version} ($status_text)"
    done

    if [[ -n "$current_php" ]]; then
        echo
        log_info "Currently active in Apache: PHP $current_php"
    fi
}

show_status() {
    log_info "Service Status:"

    # Check each service
    local services=("httpd" "mysql" "dnsmasq")
    for service in "${services[@]}"; do
        local status_icon="${CROSSMARK}"
        local status_text="stopped"

        if brew_package_installed "$service"; then
            if service_running "$service"; then
                status_icon="${CHECKMARK}"
                status_text="running"

                # Additional checks for MySQL
                if [[ "$service" == "mysql" ]] && mysql_connection_test; then
                    status_text="running, accepting connections"
                elif [[ "$service" == "mysql" ]]; then
                    status_text="running, but connection issues"
                    status_icon="${WARNING}"
                fi
            else
                status_text="stopped"
                status_icon="${CROSSMARK}"
            fi
        else
            status_text="not installed"
            status_icon="⭕"
        fi

        echo "  $status_icon $service ($status_text)"
    done

    echo
    log_info "PHP Configuration:"
    local current_php=$(get_current_php_version)
    if [[ -n "$current_php" ]]; then
        echo "  ${ROCKET} Active in Apache: PHP $current_php"

        # Show if PHP binary is available in PATH
        local php_path="${BREW_PREFIX}/opt/php@${current_php}/bin/php"
        if [[ -x "$php_path" ]]; then
            local php_cli_version=$("$php_path" -v | head -1)
            echo "  📋 CLI Version: $php_cli_version"
        fi

        # Check PHP in PATH
        if command_exists php; then
            local path_php_version=$(php -v | head -1 | grep -o 'PHP [0-9]\+\.[0-9]\+\.[0-9]\+')
            echo "  🔗 PATH PHP: $path_php_version"

            # Check if PATH PHP matches Apache PHP
            local path_php_short=$(echo "$path_php_version" | grep -o '[0-9]\+\.[0-9]\+')
            if [[ "$path_php_short" == "$current_php" ]]; then
                echo "  ✅ PATH PHP matches Apache PHP"
            else
                echo "  ⚠️  PATH PHP differs from Apache PHP"
            fi
        else
            echo "  ❌ No PHP found in PATH"
        fi
    else
        echo "  ❓ No PHP module loaded in Apache"
    fi

    # Check Composer
    echo
    log_info "🎼 Composer Status:"
    if command_exists composer; then
        local composer_version=$(composer --version 2>/dev/null | head -1)
        echo "  ${CHECKMARK} $composer_version"

        # Show which PHP Composer is using
        local composer_php=$(composer config platform.php 2>/dev/null || echo "auto-detected")
        echo "  🐘 Using PHP: $composer_php"
    else
        echo "  ❌ Composer not found"
    fi

    show_mysql_info

    # Show helpful commands
    echo
    log_info "💡 Quick Commands:"
    if ! service_running httpd; then
        echo "  • Start Apache: brew services start httpd"
    fi
    if ! service_running mysql; then
        local mysql_service=$(get_installed_mysql_version)
        echo "  • Start MySQL: brew services start ${mysql_service:-mysql}"
    fi
    if ! service_running dnsmasq && brew_package_installed dnsmasq; then
        echo "  • Start dnsmasq: brew services start dnsmasq"
    fi
    echo "  • Restart all: bamp --restart"
}

restart_services() {
    log_info "Restarting services..."

    # Define services to restart
    local services=("httpd" "mysql" "dnsmasq")

    for service in "${services[@]}"; do
        if brew_package_installed "$service"; then
            if [[ "$DRY_RUN" == true ]]; then
                log_info "Would restart $service"
                continue
            fi

            log_info "Restarting $service..."
            if restart_service "$service"; then
                sleep 2
                if service_running "$service"; then
                    log_success "$service restarted successfully"
                else
                    log_warning "$service restart may have failed"
                fi
            else
                log_error "Failed to restart $service"
            fi
        else
            log_info "$service not installed - skipping"
        fi
    done

    log_success "Service restart completed"
}

stop_services() {
    log_info "Stopping services..."

    local services=("httpd" "mysql")
    for service in "${services[@]}"; do
        if service_running "$service"; then
            if [[ "$DRY_RUN" == true ]]; then
                log_info "Would stop $service"
            else
                stop_service "$service"
            fi
        fi
    done

    log_success "All services stopped"
}

uninstall_components() {
    log_error "Uninstall functionality moved to separate script"
    log_info "Use: ./bamp-uninstall.sh"
    exit 1
}

install_apache() {
    if brew_package_installed httpd; then
        log_info "Apache already installed"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would install Apache"
        return 0
    fi

    log_info "Installing Apache..."
    brew install httpd

    # Configure Apache
    configure_apache

    # Start Apache
    start_service httpd
    log_success "Apache installed and started on port ${HTTP_PORT}"
}

configure_apache() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would configure Apache"
        return 0
    fi

    # Backup existing config
    if [[ -f "$HTTPD_CONF" ]]; then
        backup_file "$HTTPD_CONF"
        log_info "Apache config backed up"
    fi

    # --- keep: base HTTP + server name + rewrite ---
    # Change HTTP Listen port
    sed -i.tmp "s|^Listen .*|Listen ${HTTP_PORT}|" "$HTTPD_CONF"

    # Fix ServerName
    if grep -q "^#ServerName" "$HTTPD_CONF"; then
        sed -i.tmp "s|^#ServerName .*|ServerName localhost:${HTTP_PORT}|" "$HTTPD_CONF"
    fi

    # Enable mod_rewrite (leave this here)
    sed -i.tmp "s|^#LoadModule rewrite_module|LoadModule rewrite_module|" "$HTTPD_CONF"

    rm -f "${HTTPD_CONF}.tmp"
    
    ensure_apache_https_prereqs

    # Create vhosts directory (harmless if already exists)
    create_dir_if_not_exists "$VHOSTS_DIR"

    # Set DirectoryIndex
    if grep -q "DirectoryIndex" "$HTTPD_CONF"; then
        sed -i.tmp 's|DirectoryIndex .*|DirectoryIndex index.php index.html|' "$HTTPD_CONF"
        rm -f "${HTTPD_CONF}.tmp"
    else
        echo "DirectoryIndex index.php index.html" >>"$HTTPD_CONF"
    fi

    # Test config
    if apache_config_test; then
        log_success "Apache configuration validated"
    else
        log_error "Apache configuration test failed!"
        exit 1
    fi

    log_success "Apache configuration validated"
}


install_mysql() {
    if brew_package_installed mysql; then
        log_info "MySQL already installed"

        if ! service_running mysql; then
            log_info "Starting MySQL..."
            start_service mysql
            sleep 5
        fi

        # Make sure CLI is stable even if installed earlier
        ensure_mysql_shims
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would install MySQL 8.4"
        return 0
    fi

    # Remove any MySQL 9.x if present
    if brew_package_installed mysql && ! brew_package_installed mysql@8.4; then
        log_warning "Removing MySQL 9.x to install MySQL 8.4"
        stop_service mysql
        brew uninstall mysql --ignore-dependencies || true
        sudo rm -rf "${BREW_PREFIX}/var/mysql" || true
    fi

    log_info "Installing MySQL 8.4 (LTS version)..."
    brew install mysql@8.4

    # Prepare datadir
    sudo rm -rf "${BREW_PREFIX}/var/mysql" || true
    create_dir_if_not_exists "${BREW_PREFIX}/var/mysql"
    user="$(whoami)"
    sudo chown -R "${user}:staff" "${BREW_PREFIX}/var/mysql"

    # Initialize MySQL
    log_info "Initializing MySQL database..."
    local mysql_prefix
    mysql_prefix="$(brew --prefix mysql@8.4 2>/dev/null || true)"
    if [[ -z "$mysql_prefix" ]]; then
        mysql_prefix="${BREW_PREFIX}/opt/mysql@8.4"
    fi

    "${mysql_prefix}/bin/mysqld" \
        --initialize-insecure \
        --user="$(whoami)" \
        --basedir="${mysql_prefix}" \
        --datadir="${BREW_PREFIX}/var/mysql"


    # Start MySQL service
    start_service mysql
    sleep 5

    # Verify connection
    if mysql_connection_test; then
        log_success "MySQL installed and running"
    else
        log_error "MySQL started but connection failed"
        return 1
    fi

    # Keep CLI stable
    ensure_mysql_shims    

    # Do security setup
    configure_mysql_security
}

configure_mysql_security() {
    log_info "Configuring MySQL security..."

    # Check if root password is already set
    if mysql -u root -e "SELECT 1;" 2>/dev/null; then
        log_info "MySQL root user has no password - setting up security"
        setup_mysql_root_password
    else
        log_info "MySQL root password appears to be already set"
        return 0
    fi
}

setup_mysql_root_password() {
    echo
    log_info "${LOCK} MySQL Security Setup"
    echo "For local development, you can:"
    echo "  1. Set a simple password (recommended for ease of use)"
    echo "  2. Set a strong password (more secure)"
    echo "  3. Keep no password (less secure, but convenient)"
    echo

    if [[ "$FORCE_MODE" == true ]]; then
        log_info "Force mode: Setting simple password 'root'"
        setup_simple_password
        return 0
    fi

    while true; do
        read -r -p "Choose option (1-3): " choice
        case $choice in
        1)
            setup_simple_password
            break
            ;;
        2)
            setup_custom_password
            break
            ;;
        3)
            setup_no_password
            break
            ;;
        *)
            log_error "Invalid choice. Please enter 1, 2, or 3"
            ;;
        esac
    done
}

setup_simple_password() {
    local password="root"

    log_info "Setting MySQL root password to 'root'"

    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${password}';" 2>/dev/null || {
        log_error "Failed to set MySQL root password"
        return 1
    }

    create_mysql_config_file "$password"
    log_success "MySQL root password set to 'root'"
    echo "💡 Connection: mysql -u root -p (password: root)"
}

setup_custom_password() {
    local password
    local password_confirm

    while true; do
        read -r -s -p "Enter MySQL root password: " password
        echo
        read -r -s -p "Confirm password: " password_confirm
        echo

        if [[ "$password" == "$password_confirm" ]]; then
            break
        else
            log_error "Passwords don't match. Please try again."
        fi
    done

    if [[ -z "$password" ]]; then
        log_error "Password cannot be empty"
        return 1
    fi

    log_info "Setting custom MySQL root password"

    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${password}';" 2>/dev/null || {
        log_error "Failed to set MySQL root password"
        return 1
    }

    create_mysql_config_file "$password"
    log_success "MySQL root password set successfully"
    echo "💡 Connection: mysql -u root -p"
}

setup_no_password() {
    log_warning "Keeping MySQL root user without password"
    log_info "This is convenient but less secure for local development"

    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '';" 2>/dev/null || true

    log_success "MySQL configured without root password"
    echo "💡 Connection: mysql -u root"
}

create_mysql_config_file() {
    local password="$1"
    local mysql_config="$HOME/.my.cnf"

    log_info "Creating MySQL config file for convenience"

    cat >"$mysql_config" <<EOF
[client]
user = root
password = ${password}
host = localhost
port = ${MYSQL_PORT}

[mysql]
database = mysql

[mysqldump]
user = root
password = ${password}
EOF

    chmod 600 "$mysql_config"
    log_success "MySQL config created: $mysql_config"
    echo "💡 You can now use 'mysql' command without entering credentials"
}

install_dnsmasq() {
    local DNSMASQ_PORT=53535

    if brew_package_installed dnsmasq; then
        log_info "dnsmasq already installed"

        if ! command_exists dnsmasq; then
            log_info "dnsmasq not linked, linking now..."
            if ! brew link dnsmasq; then
                log_warning "Failed to link dnsmasq, trying to force link..."
                brew link --force dnsmasq || {
                    log_error "Failed to link dnsmasq even with --force"
                    return 1
                }
            fi
            log_success "dnsmasq linked successfully"
        fi

        # Check if configuration exists and is correct
        local dnsmasq_conf="${BREW_PREFIX}/etc/dnsmasq.conf"
        if [[ ! -f "$dnsmasq_conf" ]] || ! grep -q "port=${DNSMASQ_PORT}" "$dnsmasq_conf" 2>/dev/null; then
            configure_dnsmasq "$DNSMASQ_PORT"
        fi

        if ! service_running dnsmasq; then
            log_info "dnsmasq is not running"
            log_info "To start dnsmasq: brew services start dnsmasq"
        fi

        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would install dnsmasq for .test domain resolution"
        return 0
    fi

    log_info "Installing dnsmasq for .test domain resolution..."

    if ! brew install dnsmasq; then
        log_error "Failed to install dnsmasq via Homebrew"
        return 1
    fi

    if ! brew_package_installed dnsmasq; then
        log_error "dnsmasq installation verification failed"
        return 1
    fi

    # Link dnsmasq
    log_info "Linking dnsmasq..."
    if ! brew link dnsmasq; then
        log_warning "Failed to link dnsmasq, trying to force link..."
        brew link --force dnsmasq || {
            log_error "Failed to link dnsmasq even with --force"
            return 1
        }
    fi

    log_success "dnsmasq installed and linked successfully"

    configure_dnsmasq "$DNSMASQ_PORT"

    log_info "Starting dnsmasq on port $DNSMASQ_PORT..."
    if start_service dnsmasq; then
        sleep 2
        if service_running dnsmasq; then
            log_success "dnsmasq installed and started successfully"
        else
            log_warning "dnsmasq installed but may not be running properly"
        fi
    else
        log_warning "dnsmasq installed but failed to start"
    fi

    return 0
}

configure_dnsmasq() {
    local dnsmasq_port="$1"
    local dnsmasq_conf="${BREW_PREFIX}/etc/dnsmasq.conf"

    log_info "Configuring dnsmasq for .test domains on port $dnsmasq_port..."

    if [[ -f "$dnsmasq_conf" ]]; then
        backup_file "$dnsmasq_conf"
    fi

    cat >"$dnsmasq_conf" <<EOF
# BAMP dnsmasq configuration
# Use custom port to avoid requiring sudo
port=${dnsmasq_port}

# Resolve .test domains to localhost
address=/.test/127.0.0.1

# Don't read /etc/hosts
no-hosts

# Don't read /etc/resolv.conf
no-resolv

# Only bind to localhost
listen-address=127.0.0.1

# Log queries for debugging (optional)
# log-queries
EOF

    # Configure system resolver with custom port
    if ! sudo mkdir -p /etc/resolver; then
        log_error "Failed to create /etc/resolver directory"
        return 1
    fi

    if ! cat <<EOF | sudo tee /etc/resolver/test >/dev/null; then
nameserver 127.0.0.1
port ${dnsmasq_port}
EOF
        log_error "Failed to create system resolver configuration"
        return 1
    fi

    log_success "dnsmasq configuration updated"
}

install_ssl_support() {
    if brew_package_installed mkcert; then
        log_info "SSL support already installed"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would install SSL support (mkcert)"
        return 0
    fi

    log_info "Installing SSL support..."
    brew install mkcert nss
    mkcert -install

    create_wildcard_certificate
    log_success "SSL support installed"
}

create_wildcard_certificate() {

    command -v mkcert >/dev/null 2>&1 || { log_error "mkcert not found"; return 1; }

    local cert_path="$CERT_PATH"

    create_dir_if_not_exists "$cert_path"

    if [[ -f "${cert_path}/_wildcard.test.pem" ]]; then
        log_info "Wildcard SSL certificate for *.test already exists"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create wildcard SSL certificate for *.test domains"
        return 0
    fi

    log_info "Creating wildcard SSL certificate for *.test domains..."

    # Ask mkcert to write with explicit names so we don't guess its output filename
    mkcert \
        -cert-file "${cert_path}/_wildcard.test.pem" \
        -key-file  "${cert_path}/_wildcard.test-key.pem" \
        "*.test" "test"

    chmod 644 "${cert_path}/_wildcard.test.pem"
    chmod 600 "${cert_path}/_wildcard.test-key.pem"

    log_success "Wildcard SSL certificate created for *.test domains"
}


install_php() {
    local php_version="${1:-$DEFAULT_PHP}"

    if ! is_valid_php_version "$php_version"; then
        log_error "Invalid PHP version: $php_version"
        log_info "Available versions: ${PHP_VERSIONS[*]}"
        return 1
    fi

    if brew_package_installed "php@${php_version}"; then
        log_info "PHP ${php_version} already installed"
    else
        if [[ "$DRY_RUN" == true ]]; then
            log_info "Would install PHP ${php_version}"
        else
            log_info "Installing PHP ${php_version}..."
            if ! brew install "php@${php_version}"; then
                log_error "Failed to install PHP ${php_version}"
                return 1
            fi
            log_success "PHP ${php_version} installed successfully"
        fi
    fi

    configure_php "$php_version"
    switch_php_version "$php_version"

    log_success "PHP ${php_version} is now active in Apache"

    install_composer
    return 0
}

configure_php() {
    local php_version="$1"
    local php_path="${BREW_PREFIX}/opt/php@${php_version}"
    local php_ini="${BREW_PREFIX}/etc/php/${php_version}/php.ini"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would configure PHP ${php_version}"
        return 0
    fi

    local system_timezone=$(get_system_timezone)

    if [[ -f "$php_ini" ]]; then
        log_info "Configuring PHP ${php_version} settings..."

        backup_file "$php_ini"

        # Enable common development settings
        sed -i.tmp 's/display_errors = Off/display_errors = On/' "$php_ini"
        sed -i.tmp 's/error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT/error_reporting = E_ALL/' "$php_ini"

        # Set timezone
        local escaped_timezone="${system_timezone//\//\\/}"
        sed -i.tmp "s/;date.timezone =/date.timezone = ${escaped_timezone}/" "$php_ini"

        # Increase limits for development
        sed -i.tmp 's/upload_max_filesize = 2M/upload_max_filesize = 128M/' "$php_ini"
        sed -i.tmp 's/post_max_size = 8M/post_max_size = 128M/' "$php_ini"
        sed -i.tmp 's/max_execution_time = 30/max_execution_time = 300/' "$php_ini"
        sed -i.tmp 's/memory_limit = 128M/memory_limit = 256M/' "$php_ini"

        rm -f "${php_ini}.tmp"

        log_success "PHP ${php_version} configured successfully"
        log_info "PHP timezone set to: $system_timezone"
    else
        log_warning "PHP.ini not found at: $php_ini"
        return 1
    fi
}

install_composer() {
    if command_exists composer; then
        log_info "Composer already installed"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would install Composer"
        return 0
    fi

    log_info "Installing Composer..."

    local temp_dir=$(mktemp -d)
    local original_dir=$(pwd)

    cd "$temp_dir" || {
        log_error "Failed to create temporary directory"
        return 1
    }

    if ! php -d error_reporting=0 -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" 2>/dev/null; then
        log_error "Failed to download Composer installer"
        cd "$original_dir"
        rm -rf "$temp_dir"
        return 1
    fi

    if ! php -d error_reporting=0 composer-setup.php --install-dir="${BREW_PREFIX}/bin" --filename=composer --quiet 2>/dev/null; then
        log_error "Failed to install Composer"
        rm -f composer-setup.php
        cd "$original_dir"
        rm -rf "$temp_dir"
        return 1
    fi

    rm -f composer-setup.php
    cd "$original_dir"
    rm -rf "$temp_dir"

    # Get the current PHP version and update composer alias
    local current_php_version=$(php -v | head -1 | grep -o 'PHP [0-9]\+\.[0-9]\+' | grep -o '[0-9]\+\.[0-9]\+')
    if [[ -n "$current_php_version" ]]; then
        update_composer_alias "$current_php_version"
    fi

    log_success "Composer installed successfully"
}

switch_php_version() {
    local php_version="$1"
    local php_path="${BREW_PREFIX}/opt/php@${php_version}"

    if [[ ! -d "$php_path" ]]; then
        log_error "PHP ${php_version} is not installed"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would switch Apache to PHP ${php_version}"
        log_info "Would update PATH to use PHP ${php_version}"
        return 0
    fi

    log_info "Switching Apache to PHP ${php_version}..."

    if [[ ! -f "$HTTPD_CONF" ]]; then
        log_error "Apache configuration not found at: $HTTPD_CONF"
        return 1
    fi

    backup_file "$HTTPD_CONF"

    if [[ ! -f "${php_path}/lib/httpd/modules/libphp.so" ]]; then
        log_error "PHP module not found at: ${php_path}/lib/httpd/modules/libphp.so"
        return 1
    fi

    # Remove existing PHP module lines
    grep -v "LoadModule php.*_module.*libphp" "$HTTPD_CONF" >"${HTTPD_CONF}.tmp"
    mv "${HTTPD_CONF}.tmp" "$HTTPD_CONF"

    # Add new PHP module line
    local load_module="LoadModule php_module ${php_path}/lib/httpd/modules/libphp.so"

    awk -v new_line="$load_module" '
        /^LoadModule/ && !inserted {
            print new_line;
            inserted=1
        }
        { print }
        END { if (!inserted) print new_line }
    ' "$HTTPD_CONF" >"${HTTPD_CONF}.new"

    mv "${HTTPD_CONF}.new" "$HTTPD_CONF"

    # Add PHP handler if not present
    if ! grep -q "AddType application/x-httpd-php .php" "$HTTPD_CONF"; then
        echo "AddType application/x-httpd-php .php" >>"$HTTPD_CONF"
    fi

    # Test Apache config
    if ! apache_config_test; then
        log_error "Apache configuration test failed!"
        log_info "Restoring backup configuration..."
        return 1
    fi

    # Restart Apache
    if ! restart_service httpd; then
        log_error "Failed to restart Apache"
        log_info "Restoring backup configuration..."
        return 1
    fi

    # Update PATH for PHP CLI and Composer
    update_php_path "$php_version"

    # Update Composer alias to use correct PHP version
    update_composer_alias "$php_version"

    # Check if aliases already exist before creating them
    local shell_profile=""
    case "$SHELL" in
    */zsh) shell_profile="$HOME/.zshrc" ;;
    */bash) shell_profile="$HOME/.bash_profile" ;;
    esac

    if [[ -n "$shell_profile" ]] && [[ -f "$shell_profile" ]]; then
        if ! grep -q "# BAMP PHP Aliases" "$shell_profile"; then
            log_info "Creating PHP version aliases for convenience..."
            create_php_aliases
        else
            log_info "PHP aliases already exist (run 'bamp --create-aliases' to update)"
        fi
    fi

    log_success "Apache switched to PHP ${php_version}"
    log_info "PHP CLI and Composer now use PHP ${php_version}"
}

update_composer_alias() {
    local php_version="$1"
    local php_bin_path="${BREW_PREFIX}/opt/php@${php_version}/bin/php"
    local composer_path="${BREW_PREFIX}/bin/composer"

    # Update shell profile based on detected shell
    local shell_profile=""
    case "$SHELL" in
    */zsh)
        shell_profile="$HOME/.zshrc"
        ;;
    */bash)
        shell_profile="$HOME/.bash_profile"
        ;;
    *)
        log_warning "Unknown shell: $SHELL"
        return 1
        ;;
    esac

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would update Composer alias to use PHP ${php_version}"
        return 0
    fi

    log_info "Updating Composer alias to use PHP ${php_version}..."

    # Remove ALL existing composer aliases (MAMP, BAMP, or any other)
    if [[ -f "$shell_profile" ]]; then
        # Create backup
        cp "$shell_profile" "${shell_profile}.bamp.backup"

        # Remove any existing composer alias lines
        grep -v "^alias composer=" "$shell_profile" >"${shell_profile}.tmp"
        mv "${shell_profile}.tmp" "$shell_profile"
    fi

    # Add new composer alias pointing to current PHP version
    cat >>"$shell_profile" <<EOF

# BAMP Composer Alias - Managed by BAMP script
alias composer='${php_bin_path} ${composer_path}'  # BAMP Composer Alias
EOF

    log_success "Composer alias updated to use PHP ${php_version}"
}

update_php_path() {
    local php_version="$1"
    local php_bin_path="${BREW_PREFIX}/opt/php@${php_version}/bin"

    # Update shell profile based on detected shell
    local shell_profile=""
    case "$SHELL" in
    */zsh)
        shell_profile="$HOME/.zshrc"
        ;;
    */bash)
        shell_profile="$HOME/.bash_profile"
        ;;
    *)
        log_warning "Unknown shell: $SHELL"
        return 1
        ;;
    esac

    # Remove existing PHP PATH entries
    if [[ -f "$shell_profile" ]]; then
        # Create backup
        cp "$shell_profile" "${shell_profile}.bamp.backup"

        # Remove old BAMP PHP PATH entries
        grep -v "# BAMP PHP PATH" "$shell_profile" >"${shell_profile}.tmp"
        mv "${shell_profile}.tmp" "$shell_profile"
    fi

    # Add new PHP PATH
    cat >>"$shell_profile" <<EOF

# BAMP PHP PATH - Managed by BAMP script
export PATH="${php_bin_path}:\$PATH"  # BAMP PHP PATH
EOF

    log_info "Updated $shell_profile to use PHP ${php_version}"
}

source_shell_profile() {
    local shell_profile="$1"

    if [[ -z "$shell_profile" ]] || [[ ! -f "$shell_profile" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would source $shell_profile to apply changes"
        return 0
    fi

    log_info "Applying shell configuration changes..."

    # Try to source the profile in the current shell
    if source "$shell_profile" 2>/dev/null; then
        log_success "Shell configuration reloaded successfully"
        return 0
    else
        log_warning "Could not reload shell configuration automatically"
        log_info "Run 'source $shell_profile' manually to apply changes"
        return 1
    fi
}

create_php_aliases() {
    local shell_profile=""
    case "$SHELL" in
    */zsh)
        shell_profile="$HOME/.zshrc"
        ;;
    */bash)
        shell_profile="$HOME/.bash_profile"
        ;;
    *)
        log_warning "Unknown shell: $SHELL"
        return 1
        ;;
    esac

    log_info "Creating PHP version aliases..."

    # Remove existing BAMP aliases
    if [[ -f "$shell_profile" ]]; then
        grep -v "# BAMP PHP Aliases" "$shell_profile" >"${shell_profile}.tmp"
        mv "${shell_profile}.tmp" "$shell_profile"
    fi

    # Add new aliases
    cat >>"$shell_profile" <<EOF

# BAMP PHP Aliases - Managed by BAMP script
alias php82='${BREW_PREFIX}/opt/php@8.2/bin/php'          # BAMP PHP Aliases
alias php83='${BREW_PREFIX}/opt/php@8.3/bin/php'          # BAMP PHP Aliases
alias php84='${BREW_PREFIX}/opt/php@8.4/bin/php'          # BAMP PHP Aliases
alias composer82='${BREW_PREFIX}/opt/php@8.2/bin/php ${BREW_PREFIX}/bin/composer'  # BAMP PHP Aliases
alias composer83='${BREW_PREFIX}/opt/php@8.3/bin/php ${BREW_PREFIX}/bin/composer'  # BAMP PHP Aliases
alias composer84='${BREW_PREFIX}/opt/php@8.4/bin/php ${BREW_PREFIX}/bin/composer'  # BAMP PHP Aliases
EOF


    log_success "PHP aliases created in $shell_profile"
    echo "Usage examples:"
    echo "  • php83 -v          # Use PHP 8.3"
    echo "  • composer83 install # Use Composer with PHP 8.3"
}

check_composer_php_version() {
    log_info "Composer PHP Version Check:"

    if command_exists composer; then
        local composer_php_version=$(composer --version 2>/dev/null | grep -o 'PHP [0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
        echo "  🎼 Composer: $composer_php_version"

        # Also show which PHP binary composer is using
        local composer_php_path=$(which php)
        echo "  📍 PHP binary: $composer_php_path"

        if [[ -n "$composer_php_path" ]]; then
            local php_version_output=$("$composer_php_path" -v | head -1)
            echo "  🐘 PHP CLI: $php_version_output"
        fi
    else
        echo "  ❌ Composer not found in PATH"
    fi

    echo
}

create_info_page() {
    local info_file="${WEBROOT}/info.php"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create PHP info page at: ${info_file}"
        return 0
    fi

    create_dir_if_not_exists "$WEBROOT"

    if [[ ! -f "$info_file" ]]; then
        cat >"$info_file" <<'EOF'
<?php
echo "<h1>🚀 BAMP Development Environment</h1>";
echo "<p><strong>BAMP</strong> = <strong>B</strong>rew + <strong>A</strong>pache + <strong>M</strong>ySQL + <strong>P</strong>HP</p>";
echo "<h2>System Information</h2>";
phpinfo();
EOF
        log_success "Created PHP info page at: http://localhost:${HTTP_PORT}/info.php"
    fi
}


show_mysql_info() {
    echo
    log_info "${DATABASE} MySQL Information:"

    if service_running mysql; then
        echo "  ${CHECKMARK} MySQL is running on port ${MYSQL_PORT}"

        if [[ -f "$HOME/.my.cnf" ]]; then
            # Check if the password in .my.cnf is empty or not
            if grep -q "password = $" "$HOME/.my.cnf" || grep -q "password =$" "$HOME/.my.cnf"; then
                echo "  🔓 Root password: None (auto-login via ~/.my.cnf)"
            else
                echo "  ${LOCK} Root password: Set (auto-login via ~/.my.cnf)"
            fi
            echo "  💡 Connect with: mysql (credentials from ~/.my.cnf)"
        elif mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
            echo "  🔓 Root password: None (passwordless access)"
            echo "  💡 Connect with: mysql -u root"
        else
            echo "  ${LOCK} Root password: Set (use credentials to connect)"
            echo "  💡 Connect with: mysql -u root -p"
        fi

        if [[ "${HTTP_PORT}" == "80" ]]; then
            echo "  🌐 phpMyAdmin: http://localhost/phpmyadmin"
        else
            echo "  🌐 phpMyAdmin: http://localhost:${HTTP_PORT}/phpmyadmin"
        fi
    else
        echo "  ${CROSSMARK} MySQL is not running"
        local mysql_service=$(get_installed_mysql_version)
        echo "  💡 Start with: brew services start ${mysql_service:-mysql}"
    fi
}

show_completion_message() {
    echo
    log_success "${ROCKET} ${SCRIPT_NAME} installation complete!"
    echo
    echo "🍺 BAMP = Brew + Apache + MySQL + PHP"
    echo
    echo "📋 Quick Reference:"

    if [[ "${HTTP_PORT}" == "80" ]]; then
        echo "  • Apache: http://localhost"
        echo "  • PHP Info: http://localhost/info.php"
        echo "  • phpMyAdmin: http://localhost/phpmyadmin"
    else
        echo "  • Apache: http://localhost:${HTTP_PORT}"
        echo "  • PHP Info: http://localhost:${HTTP_PORT}/info.php"
        echo "  • phpMyAdmin: http://localhost:${HTTP_PORT}/phpmyadmin"
    fi

    echo "  • Document Root: ${WEBROOT}"
    echo "  • .test domains resolve to 127.0.0.1"

    show_mysql_info

    echo
    echo "🔧 Management Commands:"
    echo "  • Check status: bamp --status"
    echo "  • Switch PHP: bamp 8.2"
    echo "  • Restart services: bamp --restart"
    echo "  • Check Composer: bamp --composer-check"
    echo "  • Create aliases: bamp --create-aliases"
    echo
    echo "💡 Pro Tips:"
    echo "  • Create virtual hosts with: bamp-vhost"
    echo "  • Use .test domains for local development"
    echo "  • Use php83, composer83 aliases for specific versions"
    echo "  • Secure MySQL: mysql_secure_installation (optional)"

    # Fix the MySQL password detection logic
    if [[ -f "$HOME/.my.cnf" ]]; then
        # If .my.cnf exists, check what's in it
        if grep -q "password = $" "$HOME/.my.cnf" || grep -q "password =$" "$HOME/.my.cnf"; then
            # Empty password in .my.cnf
            echo
            log_warning "${LOCK} Security Reminder:"
            echo "  • MySQL root has no password (convenient for local dev)"
            echo "  • Run 'mysql_secure_installation' for production-like security"
        fi
        # If password is set in .my.cnf, don't show the warning
    else
        # No .my.cnf file, test direct connection
        if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
            echo
            log_warning "${LOCK} Security Reminder:"
            echo "  • MySQL root has no password (convenient for local dev)"
            echo "  • Run 'mysql_secure_installation' for production-like security"
        fi
    fi
}

main() {
    local php_version=""
    local show_status=false
    local restart_services=false
    local composer_check=false
    local create_aliases=false

    # Make sure brew bin is first for scripts
    export PATH="${BREW_PREFIX}/bin:${PATH}"    

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help)
            show_usage
            exit 0
            ;;
        -l | --list)
            list_php_versions
            exit 0
            ;;
        --stop)
            stop_services
            exit 0
            ;;
        -s | --status)
            show_status=true
            shift
            ;;
        -r | --restart)
            restart_services=true
            shift
            ;;
        --composer-check)
            composer_check=true
            shift
            ;;
        --create-aliases)
            create_aliases=true
            shift
            ;;
        --uninstall)
            uninstall_components
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        [0-9].[0-9])
            php_version="$1"
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            show_usage
            exit 1
            ;;
        esac
    done

    # Handle composer check
    if [[ "$composer_check" == true ]]; then
        check_composer_php_version
        exit 0
    fi

    # Handle alias creation
    if [[ "$create_aliases" == true ]]; then
        create_php_aliases
        exit 0
    fi

    # Set default PHP version if none specified
    if [[ -z "$php_version" && "$show_status" == false && "$restart_services" == false ]]; then
        php_version="$DEFAULT_PHP"
    fi

    # Handle status display
    if [[ "$show_status" == true ]]; then
        show_status
        exit 0
    fi

    # Handle service restart
    if [[ "$restart_services" == true ]]; then
        restart_services
        exit 0
    fi

    # Main installation
    if [[ -z "$php_version" ]]; then
        log_error "No PHP version specified"
        show_usage
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "🔍 DRY RUN MODE - Showing what would be done"
        echo
    fi

    log_info "Installing BAMP with PHP ${php_version}"

    # Prepare filesystem first (idempotent)
    ensure_webroot

    # Install core services
    install_apache
    configure_document_root
    install_mysql
    install_dnsmasq
    install_ssl_support
    ensure_default_localhost_vhost
    install_php "$php_version"
    create_info_page
    install_phpmyadmin

    # Final verification
    log_info "Verifying services..."

    if [[ "$DRY_RUN" != true ]]; then
        if brew_package_installed mysql && ! service_running mysql; then
            start_service mysql
            sleep 3
        fi

        if brew_package_installed dnsmasq && ! service_running dnsmasq; then
            start_service dnsmasq
            sleep 1
        fi
    fi

    # At the end of main() function
    if [[ "$DRY_RUN" == true ]]; then
        log_success "Dry run completed - no changes were made"
    else
        # Source shell profile BEFORE showing completion message
        # Determine shell profile
        local shell_profile=""
        case "$SHELL" in
        */zsh) shell_profile="$HOME/.zshrc" ;;
        */bash) shell_profile="$HOME/.bash_profile" ;;
        esac

        # Source once at the end to apply all changes
        if [[ -n "$shell_profile" ]]; then
            source_shell_profile "$shell_profile"
        fi

        # THEN show completion message
        show_completion_message
    fi
}

# Run main function with all arguments
main "$@"
