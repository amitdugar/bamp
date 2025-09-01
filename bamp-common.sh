#!/bin/bash

# bamp-common
# Shared functions library for all BAMP scripts
# Source this file at the beginning of other BAMP scripts

set -euo pipefail

# Version
readonly BAMP_COMMON_VERSION="1.0.0"

# Escape code for colors
readonly ESC=$(printf '\033')

# Color codes
readonly RED="${ESC}[0;31m"
readonly GREEN="${ESC}[0;32m"
readonly YELLOW="${ESC}[1;33m"
readonly BLUE="${ESC}[0;34m"
readonly PURPLE="${ESC}[0;35m"
readonly CYAN="${ESC}[0;36m"
readonly NC="${ESC}[0m" # No Color

# Unicode symbols
readonly CHECKMARK="✅"
readonly CROSSMARK="❌"
readonly WARNING="⚠️"
readonly ROCKET="🚀"
readonly GEAR="⚙️"
readonly DATABASE="🗄️"
readonly FOLDER="📁"
readonly LOCK="🔐"
readonly KEY="🔑"
readonly BEER="🍺"

# Global configuration

readonly PHP_VERSIONS=("8.1" "8.2" "8.3" "8.4")
readonly DEFAULT_PHP="8.2"



# Global flags
VERBOSE=${VERBOSE:-false}
DRY_RUN=${DRY_RUN:-false}
FORCE_MODE=${FORCE_MODE:-false}


# ---- BAMP shared defaults (single source of truth) ----
: "${WEBROOT:=$HOME/www}"
: "${BREW_PREFIX:=$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"
: "${HTTPD_CONF:=${BREW_PREFIX}/etc/httpd/httpd.conf}"
: "${VHOSTS_DIR:=${BREW_PREFIX}/etc/httpd/extra/vhosts.d}"
: "${CERT_PATH:=${BREW_PREFIX}/etc/httpd/certs}"
: "${LOG_DIR:=${BREW_PREFIX}/var/log/httpd}"
: "${HTTP_PORT:=${BAMP_HTTP_PORT:-80}}"
: "${HTTPS_PORT:=${BAMP_HTTPS_PORT:-443}}"
: "${MYSQL_PORT:=${BAMP_MYSQL_PORT:-3306}}"
: "${DEFAULT_DOMAIN_SUFFIX:=test}"


mkdir -p "$VHOSTS_DIR" "$CERT_PATH" "$LOG_DIR"




################################################################################
# LOGGING FUNCTIONS
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $1"
    fi
}

log_progress() {
    echo -e "${CYAN}[PROGRESS]${NC} $1"
}

# Enhanced logging with timestamps
log_with_timestamp() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
    "INFO") echo -e "${BLUE}[$timestamp][INFO]${NC} $message" ;;
    "SUCCESS") echo -e "${GREEN}[$timestamp][SUCCESS]${NC} $message" ;;
    "WARNING") echo -e "${YELLOW}[$timestamp][WARNING]${NC} $message" ;;
    "ERROR") echo -e "${RED}[$timestamp][ERROR]${NC} $message" >&2 ;;
    "DEBUG") [[ "$VERBOSE" == true ]] && echo -e "${PURPLE}[$timestamp][DEBUG]${NC} $message" ;;
    esac
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

path_exists() {
    [[ -e "$1" ]]
}

is_directory() {
    [[ -d "$1" ]]
}

is_file() {
    [[ -f "$1" ]]
}

is_readable() {
    [[ -r "$1" ]]
}

is_writable() {
    [[ -w "$1" ]]
}

create_dir_if_not_exists() {
    local dir="$1"
    local permissions="${2:-755}"

    if [[ ! -d "$dir" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_info "Would create directory: $dir"
            return 0
        fi

        mkdir -p "$dir"
        chmod "$permissions" "$dir"
        log_debug "Created directory: $dir"
    fi
}

backup_file() {
    local file="$1"
    local backup_suffix="${2:-$(date +%Y%m%d_%H%M%S)}"

    if [[ -f "$file" ]]; then
        local backup_file="${file}.backup.${backup_suffix}"

        if [[ "$DRY_RUN" == true ]]; then
            log_info "Would backup: $file -> $backup_file"
            return 0
        fi

        cp "$file" "$backup_file"
        log_debug "Backed up: $file -> $backup_file"
        echo "$backup_file"
    fi
}

get_file_size() {
    local file="$1"
    if [[ -f "$file" ]]; then
        stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

get_file_size_human() {
    local file="$1"
    local size_bytes=$(get_file_size "$file")

    if [[ $size_bytes -gt 1073741824 ]]; then
        echo "$((size_bytes / 1073741824))GB"
    elif [[ $size_bytes -gt 1048576 ]]; then
        echo "$((size_bytes / 1048576))MB"
    elif [[ $size_bytes -gt 1024 ]]; then
        echo "$((size_bytes / 1024))KB"
    else
        echo "${size_bytes}B"
    fi
}

################################################################################
# VALIDATION FUNCTIONS
################################################################################

is_valid_project_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]
}

is_valid_database_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]]
}

is_valid_php_version() {
    local version="$1"
    local valid_version
    for valid_version in "${PHP_VERSIONS[@]}"; do
        if [[ "$version" == "$valid_version" ]]; then
            return 0
        fi
    done
    return 1
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]
}

################################################################################
# HOMEBREW FUNCTIONS
################################################################################

ensure_homebrew() {
    if ! command_exists brew; then
        log_error "Homebrew is not installed"
        log_info "Install it from: https://brew.sh"
        return 1
    fi

    log_debug "Homebrew found at: $(which brew)"
    return 0
}

brew_package_installed() {
    local package="$1"

    # Special handling for MySQL
    if [[ "$package" == "mysql" ]]; then
        brew list mysql@8.4 &>/dev/null || brew list mysql &>/dev/null
    else
        brew list "$package" &>/dev/null
    fi
}

get_installed_mysql_version() {
    if brew list mysql@8.4 &>/dev/null; then
        echo "mysql@8.4"
    elif brew list mysql &>/dev/null; then
        echo "mysql"
    else
        echo ""
    fi
}

################################################################################
# SERVICE MANAGEMENT
################################################################################

service_running() {
    local service="$1"

    if [[ "$service" == "mysql" ]]; then
        brew services list 2>/dev/null | grep -q "^mysql@8.4.*started" ||
            brew services list 2>/dev/null | grep -q "^mysql.*started" || false
    elif [[ "$service" == "dnsmasq" ]]; then
        brew services list 2>/dev/null | grep -q "^dnsmasq.*started" ||
            pgrep -f "dnsmasq" >/dev/null 2>&1 || false
    else
        brew services list 2>/dev/null | grep -q "^$service.*started" || false
    fi
}

start_service() {
    local service="$1"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would start service: $service"
        return 0
    fi

    log_info "Starting $service..."

    if [[ "$service" == "mysql" ]]; then
        local mysql_service=$(get_installed_mysql_version)
        if [[ -n "$mysql_service" ]]; then
            brew services start "$mysql_service"
        else
            log_error "MySQL not installed"
            return 1
        fi
    else
        brew services start "$service"
    fi
}

stop_service() {
    local service="$1"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would stop service: $service"
        return 0
    fi

    log_info "Stopping $service..."

    if [[ "$service" == "mysql" ]]; then
        # Stop both possible MySQL services
        brew services stop mysql@8.4 2>/dev/null || true
        brew services stop mysql 2>/dev/null || true
    else
        brew services stop "$service" 2>/dev/null || true
    fi
}

restart_service() {
    local service="$1"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would restart service: $service"
        return 0
    fi

    log_info "Restarting $service..."

    if [[ "$service" == "mysql" ]]; then
        local mysql_service=$(get_installed_mysql_version)
        if [[ -n "$mysql_service" ]]; then
            brew services restart "$mysql_service"
        else
            log_error "MySQL not installed"
            return 1
        fi
    else
        brew services restart "$service"
    fi
}

################################################################################
# MYSQL FUNCTIONS
################################################################################
# ---------- MySQL shim setup ----------
detect_mysql_formula() {
    # Prefer versioned formulas first; add more if you like
    for f in mysql@8.4 mysql; do
        if brew ls --versions "$f" >/dev/null 2>&1; then
        echo "$f"
        return 0
        fi
    done
    echo ""   # none installed
    return 1
}

ensure_mysql_shims() {
    local formula; formula="$(detect_mysql_formula || true)"
    if [[ -z "$formula" ]]; then
        log_warning "No MySQL formula installed yet; skipping mysql shims"
        return 0
    fi

    local opt_bin="${BREW_PREFIX}/opt/${formula}/bin"
    if [[ ! -d "$opt_bin" ]]; then
        log_warning "Expected MySQL bin dir not found: $opt_bin"
        return 0
    fi

    # Ensure Brew bin is on PATH for shells and scripts
    if [[ ":$PATH:" != *":${BREW_PREFIX}/bin:"* ]]; then
        export PATH="${BREW_PREFIX}/bin:${PATH}"
    fi

    # Symlink core client tools to a stable location
    local t
    for t in mysql mysqldump mysqladmin mysqlshow mysqlbinlog; do
        if [[ -x "${opt_bin}/${t}" ]]; then
        ln -sfn "${opt_bin}/${t}" "${BREW_PREFIX}/bin/${t}"
        log_debug "Linked ${BREW_PREFIX}/bin/${t} -> ${opt_bin}/${t}"
        fi
    done

    log_success "MySQL client shims ready (formula: ${formula})"
}

get_mysql_cmd() {
    if [[ -f "/Users/$USER/.my.cnf" ]]; then
        echo "mysql"
    else
        echo "mysql -u root"
    fi
}

mysql_connection_test() {
    local timeout="${1:-5}"

    if [[ -f "/Users/$USER/.my.cnf" ]]; then
        mysql --defaults-extra-file="/Users/$USER/.my.cnf" \
            --connect-timeout="$timeout" \
            -e "SELECT 1;" >/dev/null 2>&1
    else
        mysql -u root --connect-timeout="$timeout" \
            -e "SELECT 1;" >/dev/null 2>&1
    fi
}


database_exists() {
    local db_name="$1"
    $(get_mysql_cmd) -e "USE \`${db_name}\`;" >/dev/null 2>&1
}

get_database_size() {
    local db_name="$1"
    local size_query="SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size_MB' FROM information_schema.tables WHERE table_schema='${db_name}';"
    local size=$($(get_mysql_cmd) -e "$size_query" 2>/dev/null | tail -n 1)
    echo "${size:-0}"
}

get_database_table_count() {
    local db_name="$1"
    local count_query="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db_name}';"
    $(get_mysql_cmd) -e "$count_query" 2>/dev/null | tail -n 1
}

list_user_databases() {
    $(get_mysql_cmd) -e "SHOW DATABASES;" 2>/dev/null |
        grep -v -E "^(Database|information_schema|performance_schema|mysql|sys)$"
}

get_mysql_version() {
    $(get_mysql_cmd) -e "SELECT VERSION();" 2>/dev/null | tail -n 1
}

################################################################################
# APACHE FUNCTIONS
################################################################################

apache_config_test() {
    if command_exists httpd; then
        httpd -t 2>/dev/null
    elif [[ -x "${BREW_PREFIX}/bin/httpd" ]]; then
        "${BREW_PREFIX}/bin/httpd" -t 2>/dev/null
    else
        log_error "Apache (httpd) not found"
        return 1
    fi
}

get_current_php_version() {
    if [[ -f "$HTTPD_CONF" ]]; then
        grep -o "php@[0-9.]*" "$HTTPD_CONF" 2>/dev/null | head -1 | cut -d@ -f2
    fi
}

vhost_exists() {
    local domain="$1"
    local vhost_file="${VHOSTS_DIR}/${domain}.conf"
    [[ -f "$vhost_file" ]]
}

################################################################################
# SSL/CERTIFICATE FUNCTIONS
################################################################################

ssl_cert_exists() {
    local domain="$1"
    [[ -f "${CERT_PATH}/${domain}.pem" ]] && [[ -f "${CERT_PATH}/${domain}-key.pem" ]]
}

wildcard_cert_exists() {
    local suffix="$1"
    [[ -f "${CERT_PATH}/_wildcard.${suffix}.pem" ]] && [[ -f "${CERT_PATH}/_wildcard.${suffix}-key.pem" ]]
}

################################################################################
# PROGRESS AND UI FUNCTIONS
################################################################################

show_progress_bar() {
    local current=$1
    local total=$2
    local width=${3:-50}
    local prefix="${4:-Progress}"

    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))

    printf "\r%s [" "$prefix"
    printf "%*s" $completed | tr ' ' '='
    printf "%*s" $((width - completed)) | tr ' ' '-'
    printf "] %d%%" $percentage

    if [[ $current -eq $total ]]; then
        echo
    fi
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'

    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

confirm_action() {
    local message="$1"
    local default="${2:-no}"

    if [[ "$FORCE_MODE" == true ]]; then
        log_debug "Force mode enabled, skipping confirmation"
        return 0
    fi

    local prompt
    if [[ "$default" == "yes" ]]; then
        prompt="$message (Y/n): "
    else
        prompt="$message (y/N): "
    fi

    while true; do
        read -r -p "$prompt" response

        if [[ -z "$response" ]]; then
            response="$default"
        fi

        case "$response" in
        [Yy] | [Yy][Ee][Ss])
            return 0
            ;;
        [Nn] | [Nn][Oo])
            return 1
            ;;
        *)
            echo "Please answer 'yes' or 'no'"
            ;;
        esac
    done
}

################################################################################
# SYSTEM INFORMATION
################################################################################

get_system_timezone() {
    local timezone="UTC"

    # Try to read from symlink
    if [[ -L /etc/localtime ]]; then
        local target
        target=$(readlink /etc/localtime)
        timezone="${target##*/zoneinfo/}"
    fi

    # Fallback to realpath
    if [[ -z "$timezone" || "$timezone" == "UTC" ]]; then
        local realpath
        realpath=$(realpath /etc/localtime 2>/dev/null || echo "")
        if [[ -n "$realpath" ]]; then
            timezone="${realpath##*/zoneinfo/}"
        fi
    fi

    # Final fallback
    if [[ -z "$timezone" || "$timezone" == "UTC" ]]; then
        local tz_abbr
        tz_abbr=$(date +%Z 2>/dev/null)
        case "$tz_abbr" in
        "PST" | "PDT") timezone="America/Los_Angeles" ;;
        "MST" | "MDT") timezone="America/Denver" ;;
        "CST" | "CDT") timezone="America/Chicago" ;;
        "EST" | "EDT") timezone="America/New_York" ;;
        *) timezone="UTC" ;;
        esac
    fi

    echo "${timezone:-UTC}"
}

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "Unknown"
}

################################################################################
# ERROR HANDLING
################################################################################

setup_error_handling() {
    set -euo pipefail
    trap 'handle_error $? $LINENO $BASH_LINENO "$BASH_COMMAND" $(printf "%s " "${FUNCNAME[@]}")' ERR
}

handle_error() {
    local exit_code=$1
    local line_number=$2
    local bash_lineno=$3
    local command="$4"
    local function_stack="$5"

    log_error "Command failed with exit code $exit_code"
    log_error "Failed command: $command"
    log_error "Line number: $line_number"
    log_error "Function stack: $function_stack"

    if [[ "$VERBOSE" == true ]]; then
        log_debug "Bash line number: $bash_lineno"
        log_debug "Full command: $command"
    fi
}

cleanup_temp_files() {
    local temp_dir="${1:-/tmp}"
    local prefix="${2:-bamp_}"

    find "$temp_dir" -name "${prefix}*" -type f -mtime +1 -delete 2>/dev/null || true
    log_debug "Cleaned up temporary files"
}

################################################################################
# INITIALIZATION
################################################################################

init_bamp_common() {
    # Set up error handling
    setup_error_handling

    # Clean up old temp files
    cleanup_temp_files

    # Ensure Homebrew is available
    if ! ensure_homebrew; then
        exit 1
    fi

    log_debug "BAMP Common Library v${BAMP_COMMON_VERSION} initialized"
}

# Auto-initialize when sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    init_bamp_common
fi

################################################################################
# HELP FUNCTION
################################################################################

show_common_functions() {
    cat <<'EOF'
BAMP Common Library Functions:

LOGGING:
  log_info, log_success, log_warning, log_error, log_debug, log_progress

UTILITIES:
  command_exists, path_exists, is_directory, is_file, create_dir_if_not_exists
  backup_file, get_file_size, get_file_size_human

VALIDATION:
  is_valid_project_name, is_valid_database_name, is_valid_php_version, is_valid_domain

HOMEBREW:
  ensure_homebrew, brew_package_installed, get_installed_mysql_version

SERVICES:
  service_running, start_service, stop_service, restart_service

MYSQL:
  get_mysql_cmd, mysql_connection_test, database_exists, get_database_size
  get_database_table_count, list_user_databases, get_mysql_version

APACHE:
  apache_config_test, get_current_php_version, vhost_exists

SSL:
  ssl_cert_exists, wildcard_cert_exists

UI:
  show_progress_bar, spinner, confirm_action

SYSTEM:
  get_system_timezone, get_macos_version

ERROR HANDLING:
  setup_error_handling, handle_error, cleanup_temp_files

GLOBALS:
  Colors: RED, GREEN, YELLOW, BLUE, PURPLE, CYAN, NC
  Symbols: CHECKMARK, CROSSMARK, WARNING, ROCKET, GEAR, DATABASE, FOLDER, LOCK, KEY
  Paths: BREW_PREFIX, MYSQL_CONFIG, VHOSTS_DIR, CERT_PATH, HTTPD_CONF, LOG_DIR
  Settings: DEFAULT_PHP, PHP_VERSIONS, HTTP_PORT, HTTPS_PORT, MYSQL_PORT

EOF
}

# Show help if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "BAMP Common Library v${BAMP_COMMON_VERSION}"
    echo "This file should be sourced by other BAMP scripts."
    echo
    show_common_functions
fi


ensure_apache_https_prereqs() {
  # Preconditions
  if [[ ! -f "$HTTPD_CONF" ]]; then
    log_error "Apache config not found at: $HTTPD_CONF"
    return 1
  fi

  # 1) Ensure HTTPS Listen line exists (don’t duplicate)
  if ! grep -Eq "^[[:space:]]*Listen[[:space:]]+${HTTPS_PORT}([[:space:]]|\$)" "$HTTPD_CONF"; then
    if [[ "$DRY_RUN" == true ]]; then
      log_info "Would add: Listen ${HTTPS_PORT}"
    else
      echo "Listen ${HTTPS_PORT}" >> "$HTTPD_CONF"
      log_info "Added Listen ${HTTPS_PORT}"
    fi
  fi

  # 2) Enable required modules (uncomment if present, append if missing)
  if [[ "$DRY_RUN" == true ]]; then
    log_info "Would enable ssl_module and socache_shmcb_module"
  else
    # Uncomment typical lines if they’re present but commented
    sed -i.bampbak \
      -e 's|^[#][[:space:]]*LoadModule[[:space:]]\+ssl_module|LoadModule ssl_module|' \
      -e 's|^[#][[:space:]]*LoadModule[[:space:]]\+socache_shmcb_module|LoadModule socache_shmcb_module|' \
      "$HTTPD_CONF"

    # If still missing entirely, append canonical module lines
    grep -Eq '^[[:space:]]*LoadModule[[:space:]]+ssl_module' "$HTTPD_CONF" || \
      echo 'LoadModule ssl_module lib/httpd/modules/mod_ssl.so' >> "$HTTPD_CONF"

    grep -Eq '^[[:space:]]*LoadModule[[:space:]]+socache_shmcb_module' "$HTTPD_CONF" || \
      echo 'LoadModule socache_shmcb_module lib/httpd/modules/mod_socache_shmcb.so' >> "$HTTPD_CONF"
  fi

  # 3) Ensure vhosts include
  if ! grep -Fq "IncludeOptional ${VHOSTS_DIR}/*.conf" "$HTTPD_CONF"; then
    if [[ "$DRY_RUN" == true ]]; then
      log_info "Would add: IncludeOptional ${VHOSTS_DIR}/*.conf"
    else
      echo "IncludeOptional ${VHOSTS_DIR}/*.conf" >> "$HTTPD_CONF"
      log_info "Enabled vhosts.d include"
    fi
  fi
}



ensure_default_localhost_vhost() {

mkdir -p "$VHOSTS_DIR" "$CERT_PATH" "$LOG_DIR"

  # Make sure vhosts.d is included
  grep -Fq "IncludeOptional ${VHOSTS_DIR}/*.conf" "$HTTPD_CONF" || \
    echo "IncludeOptional ${VHOSTS_DIR}/*.conf" >> "$HTTPD_CONF"

  # Create an HTTPS cert for localhost if needed
  local lc_pem="${CERT_PATH}/localhost.pem"
  local lc_key="${CERT_PATH}/localhost-key.pem"
  if [[ ! -f "$lc_pem" || ! -f "$lc_key" ]]; then
    command -v mkcert >/dev/null 2>&1 && \
      mkcert -cert-file "$lc_pem" -key-file "$lc_key" "localhost" 127.0.0.1 ::1
    chmod 644 "$lc_pem" 2>/dev/null || true
    chmod 600 "$lc_key" 2>/dev/null || true
  fi

  # Write 00-localhost.conf only once
  local vhost_file="${VHOSTS_DIR}/00-localhost.conf"
  [[ -f "$vhost_file" ]] && return 0

  sudo tee "$vhost_file" >/dev/null <<EOF
# Default localhost vhost (must be first)
<VirtualHost *:${HTTP_PORT}>
  ServerName localhost
  ServerAlias localhost.localdomain
  DocumentRoot "${WEBROOT}"
  DirectoryIndex index.php index.html
  ErrorLog  "${LOG_DIR:-${BREW_PREFIX}/var/log/httpd}/localhost-error.log"
  CustomLog "${LOG_DIR:-${BREW_PREFIX}/var/log/httpd}/localhost-access.log" common

  <Directory "${WEBROOT}">
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>

<VirtualHost *:${HTTPS_PORT}>
  ServerName localhost
  ServerAlias localhost.localdomain
  DocumentRoot "${WEBROOT}"
  DirectoryIndex index.php index.html
  ErrorLog  "${LOG_DIR:-${BREW_PREFIX}/var/log/httpd}/localhost-ssl-error.log"
  CustomLog "${LOG_DIR:-${BREW_PREFIX}/var/log/httpd}/localhost-ssl-access.log" common

  SSLEngine on
  SSLCertificateFile "${lc_pem}"
  SSLCertificateKeyFile "${lc_key}"

  <Directory "${WEBROOT}">
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>
EOF
}
