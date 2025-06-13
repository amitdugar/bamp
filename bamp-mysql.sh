#!/bin/bash

set -euo pipefail


# Get the directory where this script is actually located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Source the common functions from the same directory as this script
source "${SCRIPT_DIR}/bamp-common"

# Script-specific configuration
readonly VERSION="1.0.0"

# Override global verbose setting if needed
VERBOSE=false

show_usage() {
    cat << 'EOF'
Usage: ./bamp-mysql.sh [OPTIONS] COMMAND [ARGS]

A comprehensive MySQL utility for BAMP development environments.

COMMANDS:
    import DATABASE FILE        Import SQL file into database
    import-gz DATABASE FILE     Import compressed SQL file (.gz)
    dump DATABASE [FILE]        Export database to SQL file
    dump-gz DATABASE [FILE]     Export database to compressed SQL file
    dump-all [DIRECTORY]        Export all databases
    list                        List all databases with sizes
    create DATABASE             Create a new database
    drop DATABASE               Drop a database (with confirmation)
    restart                     Restart MySQL service
    reset-password              Reset MySQL root password
    status                      Show MySQL status and configuration
    optimize DATABASE           Optimize database tables
    check                       Check and repair database tables

OPTIONS:
    -h, --help                  Show this help message
    -v, --verbose               Enable verbose output
    -f, --force                 Skip confirmations (use with caution)
    -p, --progress              Show progress bars for operations
    --no-compress               Disable compression for dumps
    --compress-level N          Set compression level (1-9, default: 6)

EXAMPLES:
    # Import operations
    ./bamp-mysql.sh import myapp backup.sql
    ./bamp-mysql.sh import-gz staging production.sql.gz

    # Export operations
    ./bamp-mysql.sh dump myapp
    ./bamp-mysql.sh dump-gz myapp backup.sql.gz
    ./bamp-mysql.sh dump-all ~/backups/

    # Database management
    ./bamp-mysql.sh list
    ./bamp-mysql.sh create newproject
    ./bamp-mysql.sh restart
    ./bamp-mysql.sh reset-password

    # Maintenance
    ./bamp-mysql.sh optimize myapp
    ./bamp-mysql.sh check myapp

NOTES:
    • This script integrates with BAMP's MySQL 8.4 configuration
    • Uses ~/.my.cnf for authentication if available
    • Creates timestamped backups automatically
    • Supports both .sql and .sql.gz formats

EOF
}

validate_environment() {
    # Check if MySQL is installed
    if ! brew_package_installed mysql; then
        log_error "MySQL is not installed via Homebrew"
        log_info "Please install BAMP first"
        log_info "Expected: mysql@8.4 or mysql package"
        return 1
    fi

    # Check if MySQL is running
    if ! service_running mysql; then
        log_error "MySQL is not running"

        local mysql_service=$(get_installed_mysql_version)
        if [[ -n "$mysql_service" ]]; then
            log_info "Start MySQL with: brew services start $mysql_service"
        else
            log_info "Start MySQL with: brew services start mysql"
        fi
        return 1
    fi

    # Test MySQL connection
    if ! mysql_connection_test; then
        log_error "Cannot connect to MySQL"
        log_info "Check your MySQL credentials and configuration"
        log_info "For BAMP setups, try: mysql -u root"
        return 1
    fi

    return 0
}

show_mysql_status() {
    echo
    log_info "${DATABASE} MySQL Status & Configuration"
    echo

    # Service status with version detection
    if service_running mysql; then
        local mysql_service=$(get_installed_mysql_version)
        echo "  ${CHECKMARK} Service: $mysql_service running on port ${MYSQL_PORT}"
    else
        echo "  ${CROSSMARK} Service: Stopped"
        return 1
    fi

    # Connection test
    if mysql_connection_test; then
        echo "  ${CHECKMARK} Connection: OK"
    else
        echo "  ${CROSSMARK} Connection: Failed"
        return 1
    fi

    # Version information
    local mysql_version=$(get_mysql_version)
    if [[ -n "$mysql_version" ]]; then
        echo "  📋 Version: $mysql_version"
    fi

    # Configuration file
    if [[ -f "$MYSQL_CONFIG" ]]; then
        echo "  ${FOLDER} Config: $MYSQL_CONFIG"
    else
        echo "  ${FOLDER} Config: Using defaults"
    fi

    # Root user status
    if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
        echo "  🔓 Root Access: Passwordless"
    else
        echo "  ${LOCK} Root Access: Password protected"
    fi

    # Client config
    if [[ -f "/Users/$USER/.my.cnf" ]]; then
        echo "  📄 Client Config: ~/.my.cnf exists"
    fi

    # Current settings
    local sql_mode
    sql_mode=$($(get_mysql_cmd) -e "SELECT @@sql_mode;" 2>/dev/null | tail -n 1)
    if [[ -n "$sql_mode" ]]; then
        echo "  ${GEAR} SQL Mode: $sql_mode"
    fi

    local charset
    charset=$($(get_mysql_cmd) -e "SELECT @@character_set_server;" 2>/dev/null | tail -n 1)
    if [[ -n "$charset" ]]; then
        echo "  🔤 Character Set: $charset"
    fi

    # Data directory
    local data_dir
    data_dir=$($(get_mysql_cmd) -e "SELECT @@datadir;" 2>/dev/null | tail -n 1)
    if [[ -n "$data_dir" ]]; then
        echo "  ${FOLDER} Data Directory: $data_dir"
    fi

    echo
}

list_databases() {
    log_info "📊 Database List"
    echo

    # Get list of user databases
    local databases=$(list_user_databases)

    if [[ -z "$databases" ]]; then
        echo "  📭 No user databases found"
        echo
        echo "  💡 Create a new database with: ./bamp-mysql.sh create DATABASE_NAME"
        return 0
    fi

    echo "  Database Name                Size (MB)    Tables"
    echo "  ─────────────────────────────────────────────────"

    while IFS= read -r db_name; do
        if [[ -n "$db_name" ]]; then
            local size_mb=$(get_database_size "$db_name")
            local table_count=$(get_database_table_count "$db_name")
            printf "  %-30s %-12s %s\n" "$db_name" "${size_mb:-0} MB" "$table_count"
        fi
    done <<< "$databases"

    echo
}

create_database() {
    local db_name="$1"

    if [[ -z "$db_name" ]]; then
        log_error "Database name is required"
        return 1
    fi

    # Validate database name
    if ! is_valid_database_name "$db_name"; then
        log_error "Invalid database name. Use only letters, numbers, and underscores"
        return 1
    fi

    if database_exists "$db_name"; then
        log_error "Database '$db_name' already exists"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create database '$db_name'"
        return 0
    fi

    log_info "Creating database '$db_name'..."

    # Use MySQL 8.4 compatible charset and collation
    $(get_mysql_cmd) -e "CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
        log_error "Failed to create database"
        return 1
    }

    log_success "Database '$db_name' created successfully"
    echo "  🎯 Access with: mysql -u root $db_name"
}

drop_database() {
    local db_name="$1"
    local force="${2:-false}"

    if [[ -z "$db_name" ]]; then
        log_error "Database name is required"
        return 1
    fi

    if ! database_exists "$db_name"; then
        log_error "Database '$db_name' does not exist"
        return 1
    fi

    # Safety check for system databases
    if [[ "$db_name" =~ ^(information_schema|performance_schema|mysql|sys)$ ]]; then
        log_error "Cannot drop system database '$db_name'"
        return 1
    fi

    if [[ "$force" != true ]] && ! confirm_action "This will permanently delete database '$db_name' and all its data!"; then
        log_info "Operation cancelled"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would drop database '$db_name'"
        return 0
    fi

    log_info "Dropping database '$db_name'..."

    $(get_mysql_cmd) -e "DROP DATABASE \`${db_name}\`;" || {
        log_error "Failed to drop database"
        return 1
    }

    log_success "Database '$db_name' dropped successfully"
}

import_sql_file() {
    local db_name="$1"
    local sql_file="$2"
    local is_compressed="${3:-false}"

    if [[ -z "$db_name" ]] || [[ -z "$sql_file" ]]; then
        log_error "Database name and SQL file are required"
        return 1
    fi

    if [[ ! -f "$sql_file" ]]; then
        log_error "SQL file does not exist: $sql_file"
        return 1
    fi

    # Create database if it doesn't exist
    if ! database_exists "$db_name"; then
        log_info "Database '$db_name' doesn't exist, creating it..."
        create_database "$db_name" || return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would import '$sql_file' into database '$db_name'"
        return 0
    fi

    log_info "Importing '$sql_file' into database '$db_name'..."

    # Get file size for progress tracking
    local file_size_human=$(get_file_size_human "$sql_file")
    log_info "File size: $file_size_human"

    # Import the file
    local start_time=$(date +%s)

    if [[ "$is_compressed" == true ]]; then
        log_progress "Decompressing and importing..."
        gunzip -c "$sql_file" | mysql "$db_name" || {
            log_error "Failed to import compressed SQL file"
            return 1
        }
    else
        log_progress "Importing..."
        mysql "$db_name" < "$sql_file" || {
            log_error "Failed to import SQL file"
            return 1
        }
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "Import completed in ${duration} seconds"

    # Show final database info
    local table_count=$(get_database_table_count "$db_name")
    local size_mb=$(get_database_size "$db_name")

    echo "  📊 Tables: $table_count"
    echo "  💾 Size: ${size_mb}MB"
}

dump_database() {
    local db_name="$1"
    local output_file="$2"
    local compress="${3:-false}"
    local compress_level="${4:-6}"

    if [[ -z "$db_name" ]]; then
        log_error "Database name is required"
        return 1
    fi

    if ! database_exists "$db_name"; then
        log_error "Database '$db_name' does not exist"
        return 1
    fi

    # Generate output filename if not provided
    if [[ -z "$output_file" ]]; then
        local timestamp=$(date +%Y%m%d_%H%M%S)
        if [[ "$compress" == true ]]; then
            output_file="${db_name}_${timestamp}.sql.gz"
        else
            output_file="${db_name}_${timestamp}.sql"
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would dump database '$db_name' to '$output_file'"
        return 0
    fi

    log_info "Dumping database '$db_name' to '$output_file'..."

    local start_time=$(date +%s)

    # Perform the dump with MySQL 8.4 compatible options
    local dump_options="--single-transaction --routines --triggers --default-character-set=utf8mb4"

    if [[ "$compress" == true ]]; then
        log_progress "Dumping and compressing..."
        mysqldump $dump_options "$db_name" | gzip -"$compress_level" > "$output_file" || {
            log_error "Failed to dump and compress database"
            return 1
        }
    else
        log_progress "Dumping..."
        mysqldump $dump_options "$db_name" > "$output_file" || {
            log_error "Failed to dump database"
            return 1
        }
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local file_size_human=$(get_file_size_human "$output_file")

    log_success "Dump completed in ${duration} seconds"
    echo "  ${FOLDER} File: $output_file"
    echo "  💾 Size: $file_size_human"
}

dump_all_databases() {
    local output_dir="${1:-./mysql_backups_$(date +%Y%m%d_%H%M%S)}"

    log_info "Dumping all databases to directory: $output_dir"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create backup directory: $output_dir"
        local databases=$(list_user_databases)
        if [[ -n "$databases" ]]; then
            echo "Would dump databases:"
            while IFS= read -r db_name; do
                [[ -n "$db_name" ]] && echo "  • $db_name"
            done <<< "$databases"
        fi
        return 0
    fi

    # Create output directory
    create_dir_if_not_exists "$output_dir" || {
        log_error "Failed to create output directory"
        return 1
    }

    # Get list of user databases
    local databases=$(list_user_databases)

    if [[ -z "$databases" ]]; then
        log_warning "No user databases found to dump"
        return 0
    fi

    local db_count=$(echo "$databases" | wc -l | tr -d ' ')
    local current=0

    echo "  📦 Found $db_count databases to dump"
    echo

    while IFS= read -r db_name; do
        if [[ -n "$db_name" ]]; then
            ((current++))
            log_info "[$current/$db_count] Dumping $db_name..."

            local output_file="${output_dir}/${db_name}_$(date +%Y%m%d_%H%M%S).sql.gz"
            dump_database "$db_name" "$output_file" true || {
                log_warning "Failed to dump $db_name, continuing..."
                continue
            }
        fi
    done <<< "$databases"

    log_success "All database dumps completed"
    echo "  ${FOLDER} Location: $output_dir"
}

restart_mysql() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would restart MySQL service"
        return 0
    fi

    restart_service mysql

    log_info "Waiting for MySQL to start..."
    sleep 5

    # Wait for connection to be available
    local retries=0
    while [[ $retries -lt 10 ]]; do
        if mysql_connection_test; then
            log_success "MySQL restarted successfully"
            return 0
        fi
        sleep 1
        ((retries++))
    done

    log_error "MySQL started but connection failed after 10 seconds"
    return 1
}

reset_mysql_password() {
    echo
    log_info "${LOCK} MySQL Root Password Reset"
    echo
    echo "Choose reset method:"
    echo "  1. Set simple password (root)"
    echo "  2. Set custom password"
    echo "  3. Remove password (no password)"
    echo

    if [[ "$FORCE_MODE" == true ]]; then
        log_info "Force mode: Setting simple password 'root'"
        reset_to_simple_password
        return 0
    fi

    while true; do
        read -r -p "Choose option (1-3): " choice
        case $choice in
            1)
                reset_to_simple_password
                break
                ;;
            2)
                reset_to_custom_password
                break
                ;;
            3)
                reset_to_no_password
                break
                ;;
            *)
                log_error "Invalid choice. Please enter 1, 2, or 3"
                ;;
        esac
    done
}

reset_to_simple_password() {
    local password="root"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would set MySQL root password to 'root'"
        return 0
    fi

    log_info "Setting MySQL root password to 'root'"

    $(get_mysql_cmd) -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${password}';" || {
        log_error "Failed to set MySQL root password"
        return 1
    }

    update_mycnf_password "$password"
    log_success "MySQL root password set to 'root'"
    echo "💡 Connection: mysql -u root -p (password: root)"
}

reset_to_custom_password() {
    local password
    local password_confirm

    while true; do
        read -r -s -p "Enter new MySQL root password: " password
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

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would set custom MySQL root password"
        return 0
    fi

    log_info "Setting custom MySQL root password"

    $(get_mysql_cmd) -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${password}';" || {
        log_error "Failed to set MySQL root password"
        return 1
    }

    update_mycnf_password "$password"
    log_success "MySQL root password updated successfully"
    echo "💡 Connection: mysql -u root -p"
}

reset_to_no_password() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would remove MySQL root password"
        return 0
    fi

    log_warning "Removing MySQL root password"

    $(get_mysql_cmd) -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '';" 2>/dev/null || {
        log_error "Failed to remove MySQL root password"
        return 1
    }

    update_mycnf_password ""
    log_success "MySQL root password removed"
    echo "💡 Connection: mysql -u root"
}

update_mycnf_password() {
    local password="$1"
    local mycnf_file="/Users/$USER/.my.cnf"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would update ~/.my.cnf with new password"
        return 0
    fi

    if [[ -f "$mycnf_file" ]]; then
        # Backup existing file
        backup_file "$mycnf_file"

        # Update existing file
        if grep -q "^password" "$mycnf_file"; then
            sed -i.bak "s/^password = .*/password = ${password}/" "$mycnf_file"
        else
            # Add password line to [client] section
            sed -i.bak '/^\[client\]/a\
password = '"${password}" "$mycnf_file"
        fi
        log_info "Updated ~/.my.cnf with new password"
    else
        # Create new .my.cnf file
        cat > "$mycnf_file" << EOF
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
        chmod 600 "$mycnf_file"
        log_info "Created ~/.my.cnf with new password"
    fi
}

optimize_database() {
    local db_name="$1"

    if [[ -z "$db_name" ]]; then
        log_error "Database name is required"
        return 1
    fi

    if ! database_exists "$db_name"; then
        log_error "Database '$db_name' does not exist"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would optimize database '$db_name'"
        return 0
    fi

    log_info "Optimizing database '$db_name'..."

    # Get list of tables
    local tables
    tables=$($(get_mysql_cmd) -e "SHOW TABLES FROM \`${db_name}\`;" 2>/dev/null | tail -n +2)

    if [[ -z "$tables" ]]; then
        log_info "No tables found in database '$db_name'"
        return 0
    fi

    local table_count=$(echo "$tables" | wc -l | tr -d ' ')
    local current=0

    echo "  ${GEAR} Optimizing $table_count tables..."

    while IFS= read -r table_name; do
        if [[ -n "$table_name" ]]; then
            ((current++))
            log_debug "[$current/$table_count] Optimizing table: $table_name"

            show_progress_bar $current $table_count 30 "Optimizing"

            $(get_mysql_cmd) -e "OPTIMIZE TABLE \`${db_name}\`.\`${table_name}\`;" >/dev/null 2>&1 || {
                log_warning "Failed to optimize table: $table_name"
            }
        fi
    done <<< "$tables"

    log_success "Database optimization completed"
}

check_database() {
    local db_name="$1"

    if [[ -z "$db_name" ]]; then
        log_error "Database name is required"
        return 1
    fi

    if ! database_exists "$db_name"; then
        log_error "Database '$db_name' does not exist"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would check database '$db_name' for errors"
        return 0
    fi

    log_info "Checking database '$db_name' for errors..."

    # Get list of tables
    local tables
    tables=$($(get_mysql_cmd) -e "SHOW TABLES FROM \`${db_name}\`;" 2>/dev/null | tail -n +2)

    if [[ -z "$tables" ]]; then
        log_info "No tables found in database '$db_name'"
        return 0
    fi

    local table_count=$(echo "$tables" | wc -l | tr -d ' ')
    local current=0
    local errors_found=false

    echo "  🔍 Checking $table_count tables..."

    while IFS= read -r table_name; do
        if [[ -n "$table_name" ]]; then
            ((current++))
            log_debug "[$current/$table_count] Checking table: $table_name"

            show_progress_bar $current $table_count 30 "Checking"

            local check_result
            check_result=$($(get_mysql_cmd) -e "CHECK TABLE \`${db_name}\`.\`${table_name}\`;" 2>/dev/null | tail -n +2 | awk '{print $4}')

            if [[ "$check_result" != "OK" ]]; then
                log_warning "Table $table_name: $check_result"
                errors_found=true

                # Attempt repair
                log_info "Attempting to repair table: $table_name"
                $(get_mysql_cmd) -e "REPAIR TABLE \`${db_name}\`.\`${table_name}\`;" >/dev/null 2>&1
            fi
        fi
    done <<< "$tables"

    if [[ "$errors_found" == true ]]; then
        log_warning "Some table issues were found and repair was attempted"
    else
        log_success "Database check completed - no errors found"
    fi
}

main() {
    local command=""
    local compress_level=6

    echo "${DATABASE} BAMP MySQL Utility v${VERSION}"
    echo "================================"

    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--force)
                FORCE_MODE=true
                shift
                ;;
            -p|--progress)
                # Legacy option, now always enabled
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --compress-level)
                compress_level="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                command="$1"
                shift
                break
                ;;
        esac
    done

    # Validation
    if [[ "$DRY_RUN" == true ]]; then
        log_info "🔍 DRY RUN MODE - No changes will be made"
        echo
    fi

    # Validate environment (skip for dry run)
    if [[ "$DRY_RUN" != true ]]; then
        validate_environment || exit 1
    fi

    # Execute command
    case "$command" in
        import)
            if [[ $# -lt 2 ]]; then
                log_error "Import requires database name and SQL file"
                echo "Usage: bamp-mysql import DATABASE FILE"
                exit 1
            fi
            import_sql_file "$1" "$2" false
            ;;
        import-gz)
            if [[ $# -lt 2 ]]; then
                log_error "Import-gz requires database name and SQL.GZ file"
                echo "Usage: bamp-mysql import-gz DATABASE FILE"
                exit 1
            fi
            import_sql_file "$1" "$2" true
            ;;
        dump)
            if [[ $# -lt 1 ]]; then
                log_error "Dump requires database name"
                echo "Usage: bamp-mysql dump DATABASE [FILE]"
                exit 1
            fi
            dump_database "$1" "${2:-}" false "$compress_level"
            ;;
        dump-gz)
            if [[ $# -lt 1 ]]; then
                log_error "Dump-gz requires database name"
                echo "Usage: bamp-mysql dump-gz DATABASE [FILE]"
                exit 1
            fi
            dump_database "$1" "${2:-}" true "$compress_level"
            ;;
        dump-all)
            dump_all_databases "${1:-}"
            ;;
        list)
            list_databases
            ;;
        create)
            if [[ $# -lt 1 ]]; then
                log_error "Create requires database name"
                echo "Usage: bamp-mysql create DATABASE"
                exit 1
            fi
            create_database "$1"
            ;;
        drop)
            if [[ $# -lt 1 ]]; then
                log_error "Drop requires database name"
                echo "Usage: bamp-mysql drop DATABASE"
                exit 1
            fi
            drop_database "$1" "$FORCE_MODE"
            ;;
        restart)
            restart_mysql
            ;;
        reset-password)
            reset_mysql_password
            ;;
        status)
            show_mysql_status
            ;;
        optimize)
            if [[ $# -lt 1 ]]; then
                log_error "Optimize requires database name"
                echo "Usage: bamp-mysql optimize DATABASE"
                exit 1
            fi
            optimize_database "$1"
            ;;
        check)
            if [[ $# -lt 1 ]]; then
                log_error "Check requires database name"
                echo "Usage: bamp-mysql check DATABASE"
                exit 1
            fi
            check_database "$1"
            ;;
        "")
            log_error "No command specified"
            show_usage
            exit 1
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
