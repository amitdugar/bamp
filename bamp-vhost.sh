#!/bin/bash

set -euo pipefail

# Get the directory where this script is actually located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Source the common functions from the same directory as this script
source "${SCRIPT_DIR}/bamp-common"

: "${DEFAULT_DOMAIN_SUFFIX:=test}"


# Configuration
readonly SCRIPT_NAME="BAMP VHost"

# Global variables for this script
FINAL_PROJECT_NAME=""
FINAL_PUBLIC_PATH=""

show_usage() {
    cat <<EOF
Usage: bamp-vhost [OPTIONS] [PROJECT_NAME] [PUBLIC_PATH]

Create Apache virtual hosts with SSL certificates for local development.

OPTIONS:
    -h, --help          Show this help message
    -l, --list          List existing virtual hosts
    -r, --remove NAME   Remove a virtual host
    -d, --domain SUFFIX Domain suffix (default: ${DEFAULT_DOMAIN_SUFFIX:-test})
    --dry-run           Show what would be created without actually doing it

ARGUMENTS:
    PROJECT_NAME        Name for the project (e.g., myapp)
    PUBLIC_PATH         Full path to document root (e.g., /Users/user/www/myapp/public)

Examples:
    bamp-vhost                          # Interactive mode
    bamp-vhost myapp /Users/me/www/myapp/public
    bamp-vhost --list                   # Show existing vhosts
    bamp-vhost --remove myapp           # Remove myapp.test vhost
    bamp-vhost -d local myapp /path     # Create myapp.local instead of myapp.test

Note: This script requires BAMP (Brew + Apache + MySQL + PHP) to be installed.

EOF
}

list_vhosts() {
    if [[ ! -d "$VHOSTS_DIR" ]]; then
        log_warning "No virtual hosts configured yet."
        return 0
    fi

    log_info "Existing Virtual Hosts:"
    echo

    for file in "$VHOSTS_DIR"/*.conf; do
        [[ -e "$file" ]] || continue
        domain=$(grep -m1 "ServerName" "$file" | awk '{print $2}')
        echo "  - ${domain}"
    done
}

remove_vhost() {
    local project_name="$1"
    local domain="${project_name}.${DEFAULT_DOMAIN_SUFFIX:-test}"
    local vhost_file="${VHOSTS_DIR}/${domain}.conf"

    if ! vhost_exists "$domain"; then
        log_error "Virtual host for '${domain}' does not exist"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would remove virtual host file: $vhost_file"
        return 0
    fi

    if ! confirm_action "This will remove the virtual host file: $vhost_file"; then
        log_info "Removal cancelled."
        return 0
    fi

    sudo rm -f "$vhost_file"
    log_success "Virtual host '${domain}' removed successfully"
    restart_apache
}

validate_environment() {
    # Check if Apache is installed
    if ! brew_package_installed httpd; then
        log_error "Apache is not installed via Homebrew"
        log_info "Please install BAMP first"
        return 1
    fi

    # Check if mkcert is installed
    if ! command_exists mkcert; then
        log_error "mkcert is not installed"
        log_info "Install it with: brew install mkcert"
        return 1
    fi

    

    # Ensure vhosts.d directory exists
    create_dir_if_not_exists "$VHOSTS_DIR"

    # Check and include vhosts.d in httpd.conf
    if ! grep -Fq "IncludeOptional ${VHOSTS_DIR}/*.conf" "$HTTPD_CONF"; then
        if [[ "$DRY_RUN" != true ]]; then
            echo "IncludeOptional ${VHOSTS_DIR}/*.conf" | sudo tee -a "$HTTPD_CONF" >/dev/null
            log_info "Added IncludeOptional for vhosts.d/*.conf"
        else
            log_info "Would add IncludeOptional for vhosts.d/*.conf"
        fi
    fi
    
    ensure_apache_https_prereqs

    create_dir_if_not_exists "$CERT_PATH"

    ensure_default_localhost_vhost

    return 0
}

get_project_input() {
    local provided_project_name="$1"
    local default_webroot="/Users/$USER/www"

    local project_name="$provided_project_name"

    # Prompt for project name if not provided
    if [[ -z "$project_name" ]]; then
        while true; do
            read -p "Enter project name (e.g., myapp): " project_name
            if [[ -z "$project_name" ]]; then
                log_error "Project name cannot be empty"
                continue
            fi
            if ! is_valid_project_name "$project_name"; then
                log_error "Invalid project name. Use only letters, numbers, hyphens, and underscores"
                continue
            fi
            break
        done
    fi

    # Prepare options based on project name
    local suggested_path="${default_webroot}/${project_name}"
    local suggested_public="${suggested_path}/public"

    echo
    log_info "Document root options for '${project_name}':"
    echo "  1. ${suggested_path}"
    echo "  2. ${suggested_public}"
    echo "  3. Custom path"
    echo

    local public_path=""
    while true; do
        read -p "Choose option (1-3) or enter custom path: " path_choice
        case "$path_choice" in
        1)
            public_path="$suggested_path"
            break
            ;;
        2)
            public_path="$suggested_public"
            break
            ;;
        3)
            read -p "Enter full path to document root: " public_path
            break
            ;;
        /*)
            public_path="$path_choice"
            break
            ;;
        *)
            log_error "Invalid choice. Enter 1, 2, 3 or a full path"
            ;;
        esac
    done

    # Validate existence of directory
    if [[ ! -d "$public_path" ]]; then
        if confirm_action "Directory does not exist: $public_path. Create it now?"; then
            create_dir_if_not_exists "$public_path"
            log_success "Created directory: $public_path"

            # Create dummy index.php if doesn't exist
            if [[ ! -f "${public_path}/index.php" ]]; then
                cat >"${public_path}/index.php" <<EOF
<?php
echo "<h1>${ROCKET} Welcome to ${project_name}</h1>";
echo "<p>Your virtual host is working!</p>";
?>
EOF
                log_success "Created sample index.php"
            fi
        else
            log_error "Cannot proceed without valid document root"
            exit 1
        fi
    fi

    # Assign final output to globals
    FINAL_PROJECT_NAME="$project_name"
    FINAL_PUBLIC_PATH="$public_path"
}

create_ssl_certificate() {
    local domain="$1"
    local cert="${CERT_PATH}/${domain}.pem"
    local key="${CERT_PATH}/${domain}-key.pem"

    # Already exists?
    if [[ -f "$cert" && -f "$key" ]]; then
        log_info "Using existing SSL certificate for ${domain}"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create SSL certificate for ${domain}"
        return 0
    fi

    log_info "Creating SSL certificate for ${domain}..."

    create_dir_if_not_exists "$CERT_PATH"

    # Generate certs with SAN = domain + www.domain
    mkcert -cert-file "$cert" -key-file "$key" "$domain" "www.$domain"

    sudo chmod 644 "$cert"
    sudo chmod 600 "$key"

    log_success "SSL certificate created for ${domain}"
}


create_vhost_config() {
    local project_name="$1"
    local public_path="$2"
    local domain_suffix="$3"
    local domain="${project_name}.${domain_suffix}"
    local vhost_file="${VHOSTS_DIR}/${domain}.conf"

    if vhost_exists "$domain"; then
        log_error "Virtual host for '${domain}' already exists"
        log_info "Use --remove option to delete it first"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create virtual host configuration for ${domain}"
        return 0
    fi

    log_info "Creating virtual host for ${domain}..."

    local ssl_cert="${CERT_PATH}/${domain}.pem"
    local ssl_key="${CERT_PATH}/${domain}-key.pem"

    local vhost_config="
# Virtual Host for ${domain}
<VirtualHost *:${HTTP_PORT}>
    ServerName ${domain}
    ServerAlias www.${domain}
    ...
</VirtualHost>

<VirtualHost *:${HTTPS_PORT}>
    ServerName ${domain}
    ServerAlias www.${domain}
    DocumentRoot \"${public_path}\"
    ...
    SSLEngine on
    SSLCertificateFile \"${ssl_cert}\"
    SSLCertificateKeyFile \"${ssl_key}\"
    ...
</VirtualHost>
"
    echo "$vhost_config" | sudo tee "$vhost_file" >/dev/null
    log_success "Virtual host configuration saved: $vhost_file"
}



restart_apache() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would restart Apache"
        return 0
    fi

    log_info "Restarting Apache..."

    if restart_service httpd; then
        log_success "Apache restarted successfully"
    else
        log_error "Failed to restart Apache"
        log_info "Check Apache configuration with: sudo ${BREW_PREFIX}/bin/httpd -t"
        return 1
    fi
}

show_success_message() {
    local project_name="$1"
    local public_path="$2"
    local domain_suffix="$3"
    local domain="${project_name}.${domain_suffix}"

    echo
    log_success "${ROCKET} Virtual host created successfully!"
    echo
    echo "📋 Virtual Host Details:"
    echo "  • Domain: ${domain}"
    if [[ "$HTTP_PORT" == "80" ]]; then
        echo "  • HTTP:  http://${domain}"
    else
        echo "  • HTTP:  http://${domain}:${HTTP_PORT}"
    fi
    if [[ "$HTTPS_PORT" == "443" ]]; then
        echo "  • HTTPS: https://${domain}"
    else
        echo "  • HTTPS: https://${domain}:${HTTPS_PORT}"
    fi
    echo "  • Document Root: ${public_path}"
    echo
    echo "💡 Pro Tips:"
    echo "  • Your site should now be accessible at the URLs above"
    echo "  • SSL certificate is automatically trusted (thanks to mkcert)"
    echo "  • Check Apache logs in: ${LOG_DIR}/"
    echo "  • List all vhosts: bamp-vhost --list"
    if [[ "$HTTP_PORT" != "80" ]] || [[ "$HTTPS_PORT" != "443" ]]; then
        echo "  • Port config: BAMP_HTTP_PORT=${HTTP_PORT} BAMP_HTTPS_PORT=${HTTPS_PORT}"
    fi
}

main() {
    local project_name=""
    local public_path=""
    local domain_suffix="${DEFAULT_DOMAIN_SUFFIX:-test}"
    local remove_mode=false
    local remove_target=""

    echo "🍺 BAMP Virtual Host Creator"
    echo "============================"

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help)
            show_usage
            exit 0
            ;;
        -l | --list)
            validate_environment || exit 1
            list_vhosts
            exit 0
            ;;
        -r | --remove)
            if [[ -z "${2:-}" ]]; then
                log_error "Remove option requires a project name"
                exit 1
            fi
            remove_mode=true
            remove_target="$2"
            shift 2
            ;;
        -d | --domain)
            if [[ -z "${2:-}" ]]; then
                log_error "Domain option requires a suffix"
                exit 1
            fi
            domain_suffix="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [[ -z "$project_name" ]]; then
                project_name="$1"
            elif [[ -z "$public_path" ]]; then
                public_path="$1"
            else
                log_error "Too many arguments"
                show_usage
                exit 1
            fi
            shift
            ;;
        esac
    done

    # Show dry run notice
    if [[ "$DRY_RUN" == true ]]; then
        log_info "🔍 DRY RUN MODE - No changes will be made"
        echo
    fi

    # Validate environment
    validate_environment || exit 1

    # Check and configure macOS resolver for .test domains
    if [[ ! -f "/etc/resolver/test" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_info "Would create macOS resolver config at /etc/resolver/test"
        else
            log_warning "macOS resolver for .test domains not found!"
            log_info "Creating resolver config at /etc/resolver/test (requires sudo)"
            sudo mkdir -p /etc/resolver
            echo -e "nameserver 127.0.0.1\nport 53535" | sudo tee /etc/resolver/test >/dev/null
            log_success "Resolver configured for .test domains (using dnsmasq on port 53535)"
        fi
    fi

    # Handle remove mode
    if [[ "$remove_mode" == true ]]; then
        remove_vhost "$remove_target"
        exit 0
    fi

    # Get project details (interactive or from args)
    if [[ -z "$project_name" ]] || [[ -z "$public_path" ]]; then
        # Validate project name first if provided
        if [[ -n "$project_name" ]] && ! is_valid_project_name "$project_name"; then
            log_error "Invalid project name: $project_name"
            log_info "Use only letters, numbers, hyphens, and underscores"
            exit 1
        fi

        echo
        get_project_input "$project_name"
        project_name="$FINAL_PROJECT_NAME"
        public_path="$FINAL_PUBLIC_PATH"
    fi

    # Final validation of project name
    if ! is_valid_project_name "$project_name"; then
        log_error "Invalid project name: $project_name"
        log_info "Use only letters, numbers, hyphens, and underscores"
        exit 1
    fi

    local domain="${project_name}.${domain_suffix}"

    # Dry run mode
    if [[ "$DRY_RUN" == true ]]; then
        echo
        log_info "🔍 Dry Run - What would be created:"
        echo "  • Project: $project_name"
        echo "  • Domain: $domain"
        echo "  • Document Root: $public_path"
        if [[ "$HTTP_PORT" == "80" ]]; then
            echo "  • HTTP: http://${domain}"
        else
            echo "  • HTTP: http://${domain}:${HTTP_PORT}"
        fi
        if [[ "$HTTPS_PORT" == "443" ]]; then
            echo "  • HTTPS: https://${domain}"
        else
            echo "  • HTTPS: https://${domain}:${HTTPS_PORT}"
        fi

        # Check what SSL cert would be used
        if [[ "$domain" == *.test ]] && [[ -f "${CERT_PATH}/_wildcard.test.pem" ]]; then
            echo "  • SSL Certificate: Wildcard (*.test)"
        else
            echo "  • SSL Certificate: Individual (${domain})"
        fi
        exit 0
    fi

    # Create virtual host
    echo
    log_info "Creating virtual host for '${domain}'..."

    create_ssl_certificate "$domain"
    create_vhost_config "$project_name" "$public_path" "$domain_suffix"
    restart_apache
    show_success_message "$project_name" "$public_path" "$domain_suffix"
}

# Run main function with all arguments
main "$@"
