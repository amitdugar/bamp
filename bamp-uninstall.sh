#!/bin/bash

set -euo pipefail

# Get the directory where this script is actually located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Source the common functions from the same directory as this script
source "${SCRIPT_DIR}/bamp-common"

# Script-specific configuration
readonly SCRIPT_NAME="BAMP Uninstaller"

# Global variables for this script
BACKUP_MODE=true
KEEP_DATA=false

# Error handling
cleanup() {
    if [[ $? -ne 0 ]]; then
        log_error "Uninstall failed. Some components may remain."
        log_info "You may need to manually clean up remaining files."
    fi
}
trap cleanup EXIT

show_usage() {
    cat << EOF
Usage: bamp-uninstall [OPTIONS]

Safely uninstall BAMP (Brew + Apache + MySQL + PHP) development environment.

OPTIONS:
    -h, --help          Show this help message
    -f, --force         Skip confirmation prompts
    --no-backup         Skip creating backups
    --keep-data         Keep databases and user data
    --dry-run           Show what would be removed without actually doing it

SAFETY FEATURES:
    • Creates backups of configurations and databases
    • Stops services gracefully before removal
    • Lists what will be removed before proceeding
    • Option to keep user data and databases

Examples:
    bamp-uninstall                  # Interactive uninstall with backups
    bamp-uninstall --force          # Uninstall without prompts
    bamp-uninstall --keep-data      # Remove software but keep databases
    bamp-uninstall --dry-run        # Preview what would be removed

EOF
}

show_installed_components() {
    log_info "Scanning for BAMP components..."
    echo

    local found_components=false

    # Check core services
    local services=("httpd" "mysql" "phpmyadmin" "dnsmasq" "mkcert" "nss")
    echo "📦 Core Components:"
    for service in "${services[@]}"; do
        if brew_package_installed "$service"; then
            if [[ "$service" == "mysql" ]]; then
                # Show which MySQL version is installed
                local mysql_version=$(get_installed_mysql_version)
                if [[ -n "$mysql_version" ]]; then
                    echo "  ${CHECKMARK} $mysql_version (installed)"
                fi
            else
                echo "  ${CHECKMARK} $service (installed)"
            fi
            found_components=true
        else
            echo "  ⭕ $service (not installed)"
        fi
    done

    echo
    echo "🐘 PHP Versions:"
    for version in "${PHP_VERSIONS[@]}"; do
        if brew_package_installed "php@${version}"; then
            echo "  ${CHECKMARK} php@${version} (installed)"
            found_components=true
        else
            echo "  ⭕ php@${version} (not installed)"
        fi
    done

    echo
    echo "🔧 Additional Tools:"
    local tools=("composer")
    for tool in "${tools[@]}"; do
        if command_exists "$tool"; then
            echo "  ${CHECKMARK} $tool (available)"
            found_components=true
        else
            echo "  ⭕ $tool (not available)"
        fi
    done

    echo
    if [[ "$found_components" == false ]]; then
        log_info "No BAMP components found installed"
        exit 0
    fi
}

show_file_locations() {
    log_info "Configuration and data locations:"
    echo

    local locations=(
        "/etc/dnsmasq.d:DNS configuration"
        "/etc/resolver:DNS resolver configuration"
        "${BREW_PREFIX}/etc/httpd:Apache configuration"
        "${BREW_PREFIX}/etc/php:PHP configuration"
        "${BREW_PREFIX}/etc/my.cnf:MySQL configuration"
        "${BREW_PREFIX}/var/mysql:MySQL databases"
        ${LOG_DIR}:Apache logs"
        "/Users/$USER/Sites:Web documents"
        "/Users/$USER/.mkcert:SSL certificates"
        "/Users/$USER/.my.cnf:MySQL user config"
    )

    for location_info in "${locations[@]}"; do
        local path="${location_info%%:*}"
        local desc="${location_info##*:}"

        if [[ -e "$path" ]]; then
            echo "  ${FOLDER} $path ($desc)"
        fi
    done
}

create_backup() {
    if [[ "$BACKUP_MODE" == false ]]; then
        log_info "Skipping backups (--no-backup specified)"
        return 0
    fi

    local backup_dir="/Users/$USER/BAMP_Backup_$(date +%Y%m%d_%H%M%S)"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create backup in: $backup_dir"
        return 0
    fi

    log_info "Creating backup in: $backup_dir"
    create_dir_if_not_exists "$backup_dir"

    # Backup configurations
    local config_paths=(
        "${BREW_PREFIX}/etc/httpd"
        "${BREW_PREFIX}/etc/php"
        "${BREW_PREFIX}/etc/my.cnf"
        "/etc/dnsmasq.d"
        "/Users/$USER/.my.cnf"
    )

    for config_path in "${config_paths[@]}"; do
        if [[ -e "$config_path" ]]; then
            local backup_name=$(basename "$config_path")
            if [[ -d "$config_path" ]]; then
                cp -r "$config_path" "${backup_dir}/${backup_name}_config" 2>/dev/null || true
            else
                cp "$config_path" "${backup_dir}/${backup_name}" 2>/dev/null || true
            fi
            log_info "Backed up: $config_path"
        fi
    done

    # Backup MySQL databases (if MySQL is running and --keep-data not specified)
    if [[ "$KEEP_DATA" == false ]] && brew_package_installed mysql && service_running mysql; then
        log_info "Creating MySQL database backup..."
        if command_exists mysqldump; then
            # Get list of user databases
            local databases=$(list_user_databases 2>/dev/null || echo "")

            if [[ -n "$databases" ]]; then
                create_dir_if_not_exists "${backup_dir}/mysql_databases"
                while IFS= read -r db; do
                    if [[ -n "$db" ]]; then
                        $(get_mysql_cmd) -e "USE \`$db\`" 2>/dev/null && {
                            mysqldump $(get_mysql_cmd | cut -d' ' -f2-) "$db" > "${backup_dir}/mysql_databases/${db}.sql" 2>/dev/null || true
                            log_info "Backed up database: $db"
                        }
                    fi
                done <<< "$databases"
            fi
        fi
    fi

    # Create a restoration guide
    cat > "${backup_dir}/RESTORE_GUIDE.md" << EOF
# BAMP Backup Restoration Guide

This backup was created on: $(date)

## What's included:
- Apache configuration files
- PHP configuration files
- MySQL configuration files
- DNS configuration files
- MySQL database dumps (if any existed)

## To restore:
1. Reinstall BAMP using the installer script
2. Stop the services: \`brew services stop httpd mysql@8.4 dnsmasq\`
3. Copy configuration files back to their original locations
4. Import MySQL databases: \`mysql -u root database_name < database_name.sql\`
5. Restart services: \`brew services start httpd mysql@8.4 dnsmasq\`

## Original locations:
- Apache config: ${BREW_PREFIX}/etc/httpd/
- PHP config: ${BREW_PREFIX}/etc/php/
- MySQL config: ${BREW_PREFIX}/etc/my.cnf
- DNS config: /etc/dnsmasq.d/
- MySQL data: ${BREW_PREFIX}/var/mysql/

EOF

    log_success "Backup created successfully: $backup_dir"
}

stop_services() {
    log_info "Stopping BAMP services..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would stop all BAMP services"
        return 0
    fi

    local services=("httpd" "mysql" "dnsmasq")
    for service in "${services[@]}"; do
        if service_running "$service"; then
            log_info "Stopping $service..."
            stop_service "$service"
            sleep 1
        fi
    done

    log_success "Services stopped"
}

remove_packages() {
    log_info "Removing Homebrew packages..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would remove all BAMP packages"
        return 0
    fi

    # Remove PHP versions
    for version in "${PHP_VERSIONS[@]}"; do
        if brew_package_installed "php@${version}"; then
            log_info "Removing php@${version}..."
            brew uninstall "php@${version}" --ignore-dependencies 2>/dev/null || true
        fi
    done

    # Remove MySQL (both versions)
    local mysql_version=$(get_installed_mysql_version)
    if [[ -n "$mysql_version" ]]; then
        log_info "Removing $mysql_version..."
        brew uninstall "$mysql_version" --ignore-dependencies 2>/dev/null || true
    fi

    # Remove core packages
    local packages=("httpd" "phpmyadmin" "dnsmasq" "mkcert" "nss")
    for package in "${packages[@]}"; do
        if brew_package_installed "$package"; then
            log_info "Removing $package..."
            brew uninstall "$package" --ignore-dependencies 2>/dev/null || true
        fi
    done

    # Remove Composer (if installed via Homebrew)
    if brew_package_installed "composer"; then
        log_info "Removing composer..."
        brew uninstall "composer" --ignore-dependencies 2>/dev/null || true
    fi

    # Remove Composer binary if installed manually
    if [[ -f "${BREW_PREFIX}/bin/composer" ]]; then
        log_info "Removing manually installed composer..."
        rm -f "${BREW_PREFIX}/bin/composer" 2>/dev/null || true
    fi

    log_success "Packages removed"
}

remove_configuration_files() {
    log_info "Removing configuration files and directories..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would remove configuration files and directories"
        return 0
    fi

    # Homebrew configurations
    local config_paths=(
        "${BREW_PREFIX}/etc/httpd"
        "${BREW_PREFIX}/etc/php"
        "${BREW_PREFIX}/etc/my.cnf"
        "${LOG_DIR}"
    )

    if [[ "$KEEP_DATA" == false ]]; then
        config_paths+=(
            "${BREW_PREFIX}/var/mysql"
        )
    fi

    for path in "${config_paths[@]}"; do
        if [[ -e "$path" ]]; then
            log_info "Removing: $path"
            rm -rf "$path" 2>/dev/null || true
        fi
    done

    # System-level configurations
    local system_configs=(
        "/etc/dnsmasq.d"
        "/etc/resolver/test"
    )

    for path in "${system_configs[@]}"; do
        if [[ -e "$path" ]]; then
            log_info "Removing: $path"
            sudo rm -rf "$path" 2>/dev/null || true
        fi
    done

    # User-level configurations
    local user_configs=(
        "/Users/$USER/.mkcert"
    )

    if [[ "$KEEP_DATA" == false ]]; then
        user_configs+=(
            "/Users/$USER/.my.cnf"
        )
    fi

    for path in "${user_configs[@]}"; do
        if [[ -e "$path" ]]; then
            log_info "Removing: $path"
            rm -rf "$path" 2>/dev/null || true
        fi
    done

    log_success "Configuration files removed"
}

show_completion_message() {
    echo
    log_success "🗑️  BAMP uninstallation complete!"
    echo

    if [[ "$BACKUP_MODE" == true ]]; then
        echo "📦 Your configurations and data have been backed up"
        echo "   Check: /Users/$USER/BAMP_Backup_*"
        echo
    fi

    if [[ "$KEEP_DATA" == true ]]; then
        log_info "📊 MySQL databases were preserved as requested"
        echo
    fi

    echo "🧹 Cleanup completed:"
    echo "  • All BAMP services stopped"
    echo "  • Homebrew packages removed"
    echo "  • Configuration files cleaned up"
    echo "  • DNS resolver configuration removed"
    echo

    echo "💡 What's left:"
    echo "  • Your ~/Sites directory (untouched)"
    echo "  • Homebrew itself (still installed)"
    if [[ "$KEEP_DATA" == true ]]; then
        echo "  • MySQL data directory (preserved)"
        echo "  • User MySQL config (preserved)"
    fi
    echo

    echo "🔄 To reinstall BAMP later:"
    echo "  • Run the BAMP installer script"
    echo "  • Restore from backup if needed"
}

dry_run_preview() {
    echo
    log_info "🔍 DRY RUN - What would be removed:"
    echo

    echo "📦 Homebrew Packages:"
    for version in "${PHP_VERSIONS[@]}"; do
        if brew_package_installed "php@${version}"; then
            echo "  • php@${version}"
        fi
    done

    local mysql_version=$(get_installed_mysql_version)
    if [[ -n "$mysql_version" ]]; then
        echo "  • $mysql_version"
    fi

    local packages=("httpd" "phpmyadmin" "dnsmasq" "mkcert" "nss")
    for package in "${packages[@]}"; do
        if brew_package_installed "$package"; then
            echo "  • $package"
        fi
    done

    echo
    echo "📁 Configuration Directories:"
    local all_paths=(
        "/etc/dnsmasq.d"
        "/etc/resolver/test"
        "${BREW_PREFIX}/etc/httpd"
        "${BREW_PREFIX}/etc/php"
        "${BREW_PREFIX}/etc/my.cnf"
        "${LOG_DIR}"
        "/Users/$USER/.mkcert"
    )

    if [[ "$KEEP_DATA" == false ]]; then
        all_paths+=(
            "${BREW_PREFIX}/var/mysql"
            "/Users/$USER/.my.cnf"
        )
    fi

    for path in "${all_paths[@]}"; do
        if [[ -e "$path" ]]; then
            echo "  • $path"
        fi
    done

    echo
    if [[ "$BACKUP_MODE" == true ]]; then
        log_info "💾 Backups would be created before removal"
    else
        log_warning "${WARNING} No backups would be created (--no-backup)"
    fi

    if [[ "$KEEP_DATA" == true ]]; then
        log_info "📊 MySQL databases would be preserved (--keep-data)"
    fi
}

confirm_uninstall() {
    if [[ "$FORCE_MODE" == true ]]; then
        log_info "Force mode enabled, skipping confirmations"
        return 0
    fi

    log_warning "${WARNING} This will completely remove your BAMP development environment!"
    echo
    echo "This includes:"
    echo "  • All PHP versions (${PHP_VERSIONS[*]})"
    echo "  • Apache web server and configuration"
    if [[ "$KEEP_DATA" == false ]]; then
        echo "  • MySQL server and ALL databases"
    else
        echo "  • MySQL server (databases will be preserved)"
    fi
    echo "  • DNS configuration for .test domains"
    echo "  • SSL certificates"
    echo

    if [[ "$BACKUP_MODE" == true ]]; then
        log_info "💾 Backups will be created before removal"
    else
        log_warning "${WARNING} No backups will be created!"
    fi

    echo
    if ! confirm_action "Are you absolutely sure you want to continue? This action cannot be easily undone!"; then
        log_info "Uninstall cancelled"
        exit 0
    fi

    echo
    echo "Final confirmation required."
    echo "Type exactly 'REMOVE BAMP' (all caps) to proceed:"
    echo

    local confirmation
    read -r -p "> " confirmation

    if [[ "$confirmation" != "REMOVE BAMP" ]]; then
        log_info "Uninstall cancelled - confirmation text did not match"
        exit 0
    fi
}

main() {
    echo "🗑️  $SCRIPT_NAME"
    echo "==================="
    echo "Brew + Apache + MySQL + PHP"
    echo

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -f|--force)
                FORCE_MODE=true
                shift
                ;;
            --no-backup)
                BACKUP_MODE=false
                shift
                ;;
            --keep-data)
                KEEP_DATA=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Show dry run notice
    if [[ "$DRY_RUN" == true ]]; then
        log_info "🔍 DRY RUN MODE - No changes will be made"
        echo
    fi

    # Check if Homebrew exists
    if ! ensure_homebrew; then
        log_error "Homebrew not found. Nothing to uninstall."
        exit 1
    fi

    # Show what's installed
    show_installed_components

    # Dry run mode
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_preview
        exit 0
    fi

    echo
    show_file_locations

    echo
    # Confirmation process
    confirm_uninstall

    echo
    log_info "${ROCKET} Starting BAMP uninstallation..."

    # Execute uninstall steps
    create_backup
    stop_services
    remove_packages
    remove_configuration_files

    # Clean up Homebrew
    log_info "Cleaning up Homebrew..."
    brew cleanup 2>/dev/null || true

    show_completion_message
}

# Run main function with all arguments
main "$@"
