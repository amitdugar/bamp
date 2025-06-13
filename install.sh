#!/bin/bash

# BAMP Global Installer
# Makes BAMP commands available globally on your system

set -euo pipefail

# Configuration
readonly GITHUB_REPO="amitdugar/bamp"
readonly GITHUB_BRANCH="main"
readonly BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Global variables
BIN_DIR=""
SHELL_NAME=""
PROFILE_FILE=""

# Download and source bamp-common first - everything depends on this
download_and_source_common() {
    echo "🍺 BAMP Global Installer"
    echo "========================"
    echo "Downloading BAMP common functions..."

    # Create a temporary directory for bamp-common
    local temp_dir=$(mktemp -d)
    local common_script="$temp_dir/bamp-common"

    # Download bamp-common.sh but save as bamp-common - if this fails, we can't proceed
    if ! curl -fsSL "$BASE_URL/bamp-common.sh" -o "$common_script" 2>/dev/null; then
        echo "ERROR: Failed to download bamp-common.sh from $BASE_URL/bamp-common.sh"
        echo "Cannot proceed with installation."
        rm -rf "$temp_dir"
        exit 1
    fi

    # Make it executable and source it
    chmod +x "$common_script"

    # Source it to get all the common functions
    if ! source "$common_script"; then
        echo "ERROR: Failed to load bamp-common functions"
        rm -rf "$temp_dir"
        exit 1
    fi

    # Now we have all the common functions and can use proper logging
    log_success "BAMP common functions loaded successfully"

    # Clean up temp directory when script exits
    trap "rm -rf '$temp_dir'" EXIT
}

print_header() {
    echo
    log_info "${BEER} BAMP Global Installer ${BEER}"
    echo "┌────────────────────────────────────────────────────────────────┐"
    echo "│  Install BAMP commands globally on your system                │"
    echo "└────────────────────────────────────────────────────────────────┘"
    echo
}

# Check prerequisites (now using common functions)
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if curl is available
    if ! command_exists curl; then
        log_error "curl is required but not installed"
        log_info "Please install curl and try again"
        exit 1
    fi

    # Check if we can write to HOME
    if [[ ! -w "$HOME" ]]; then
        log_error "Cannot write to home directory: $HOME"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Detect shell and profile file
detect_shell() {
    log_info "Detecting shell configuration..."

    # Get the actual current shell from $SHELL environment variable
    local current_shell=$(basename "$SHELL")

    case "$current_shell" in
    "zsh")
        SHELL_NAME="zsh"
        PROFILE_FILE="$HOME/.zshrc"
        ;;
    "bash")
        SHELL_NAME="bash"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            PROFILE_FILE="$HOME/.bash_profile"
        else
            PROFILE_FILE="$HOME/.bashrc"
        fi
        ;;
    "fish")
        SHELL_NAME="fish"
        PROFILE_FILE="$HOME/.config/fish/config.fish"
        # Create config directory if it doesn't exist
        mkdir -p "$(dirname "$PROFILE_FILE")"
        ;;
    *)
        # Fallback to checking version variables
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            SHELL_NAME="zsh"
            PROFILE_FILE="$HOME/.zshrc"
        elif [[ -n "${BASH_VERSION:-}" ]]; then
            SHELL_NAME="bash"
            PROFILE_FILE="$HOME/.bash_profile"
        else
            SHELL_NAME="unknown"
            PROFILE_FILE="$HOME/.profile"
        fi
        ;;
    esac

    log_info "Detected shell: $SHELL_NAME ($current_shell)"
    log_info "Using profile: $PROFILE_FILE"
}

# Create bin directory (now using common functions)
create_bin_directory() {
    BIN_DIR="$HOME/bin"

    create_dir_if_not_exists "$BIN_DIR"
    log_info "Using directory: $BIN_DIR"
}

# Download and install all BAMP scripts
download_and_install_scripts() {
    log_info "Downloading and installing BAMP scripts to $BIN_DIR..."

    # Define scripts to download with source:target mapping
    # Note: source files have .sh extension on GitHub, but we save without extension locally
    local scripts=(
        "bamp-common.sh:bamp-common"
        "bamp.sh:bamp"
        "bamp-vhost.sh:bamp-vhost"
        "bamp-mysql.sh:bamp-mysql"
        "bamp-uninstall.sh:bamp-uninstall"
    )

    local failed_downloads=0

    for script_pair in "${scripts[@]}"; do
        local source_name="${script_pair%:*}"
        local target_name="${script_pair#*:}"
        local target_path="$BIN_DIR/$target_name"

        log_info "Installing $target_name..."

        if curl -fsSL "$BASE_URL/$source_name" -o "$target_path"; then
            chmod +x "$target_path"
            log_success "Installed $target_name"
        else
            log_error "Failed to download $source_name"
            ((failed_downloads++))
        fi
    done

    if [[ $failed_downloads -gt 0 ]]; then
        log_error "$failed_downloads script(s) failed to download"
        exit 1
    fi

    log_success "All BAMP scripts installed to $BIN_DIR"
}

# Update PATH in shell profile
update_path() {
    log_info "Updating PATH in $PROFILE_FILE..."

    # Create profile file if it doesn't exist
    if [[ ! -f "$PROFILE_FILE" ]]; then
        touch "$PROFILE_FILE"
        log_info "Created $PROFILE_FILE"
    fi

    # Check if PATH already contains ~/bin
    if grep -q 'export PATH="$HOME/bin:$PATH"' "$PROFILE_FILE" 2>/dev/null ||
       grep -q 'export PATH="$HOME/bin:\$PATH"' "$PROFILE_FILE" 2>/dev/null; then
        log_info "PATH already configured in $PROFILE_FILE"
    else
        # Add PATH configuration
        {
            echo ''
            echo '# BAMP - Add ~/bin to PATH'
            if [[ "$SHELL_NAME" == "fish" ]]; then
                echo 'set -gx PATH $HOME/bin $PATH'
            else
                echo 'export PATH="$HOME/bin:$PATH"'
            fi
        } >> "$PROFILE_FILE"

        log_success "Added $HOME/bin to PATH in $PROFILE_FILE"
    fi
}

# Test installation (now using common functions)
test_installation() {
    log_info "Testing BAMP installation..."

    # Update PATH for current session
    export PATH="$HOME/bin:$PATH"

    # Test if bamp command is available
    if command_exists bamp; then
        log_success "BAMP commands are now available globally!"
        echo ""
        log_info "Available commands:"
        echo "  ${CYAN}bamp${NC}           - Core installation and PHP switching"
        echo "  ${CYAN}bamp-vhost${NC}     - Virtual host management"
        echo "  ${CYAN}bamp-mysql${NC}     - Database operations"
        echo "  ${CYAN}bamp-uninstall${NC} - Safe removal"
        echo ""

        # Test if bamp script can source bamp-common successfully
        if "$HOME/bin/bamp" --help >/dev/null 2>&1; then
            log_success "BAMP scripts are working correctly"
        else
            log_warning "BAMP scripts may have issues - check manually"
        fi

        log_info "Try: ${CYAN}bamp --help${NC}"
    else
        log_error "Installation verification failed"
        log_info "You may need to restart your terminal or run:"
        echo "  ${CYAN}source $PROFILE_FILE${NC}"
        return 1
    fi
}

# Uninstall function
uninstall_bamp() {
    log_info "Uninstalling BAMP global commands..."

    # Remove scripts
    local scripts=("bamp" "bamp-common" "bamp-vhost" "bamp-mysql" "bamp-uninstall")
    local removed_count=0

    for script in "${scripts[@]}"; do
        if [[ -f "$HOME/bin/$script" ]]; then
            rm -f "$HOME/bin/$script"
            ((removed_count++))
            log_info "Removed $script"
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        log_success "Removed $removed_count BAMP script(s)"
    else
        log_info "No BAMP scripts found to remove"
    fi

    # Remove PATH entry from profile
    if [[ -f "$PROFILE_FILE" ]]; then
        # Create backup
        cp "$PROFILE_FILE" "$PROFILE_FILE.bamp-backup-$(date +%Y%m%d_%H%M%S)"

        # Remove BAMP PATH entries (handle both bash/zsh and fish)
        if [[ "$SHELL_NAME" == "fish" ]]; then
            grep -v 'BAMP - Add ~/bin to PATH' "$PROFILE_FILE" |
                grep -v 'set -gx PATH $HOME/bin $PATH' > "$PROFILE_FILE.tmp" &&
                mv "$PROFILE_FILE.tmp" "$PROFILE_FILE"
        else
            grep -v 'BAMP - Add ~/bin to PATH' "$PROFILE_FILE" |
                grep -v 'export PATH="$HOME/bin:$PATH"' |
                grep -v 'export PATH="$HOME/bin:\$PATH"' > "$PROFILE_FILE.tmp" &&
                mv "$PROFILE_FILE.tmp" "$PROFILE_FILE"
        fi

        log_success "Removed BAMP from $PROFILE_FILE"
        log_info "Backup saved as $PROFILE_FILE.bamp-backup-*"
    fi

    log_success "BAMP global commands uninstalled"
    log_info "Restart your terminal for changes to take effect"
}

# Show usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  install     Install BAMP commands globally (default)"
    echo "  uninstall   Remove BAMP global commands"
    echo "  --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                # Install BAMP globally"
    echo "  $0 install        # Install BAMP globally"
    echo "  $0 uninstall      # Remove BAMP global commands"
    echo ""
    echo "Remote installation:"
    echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/install.sh | bash"
}

# Main installation process
main() {
    # FIRST: Download and source bamp-common - everything depends on this
    download_and_source_common

    # NOW we can use all the common functions and proper logging
    print_header

    # Handle command line arguments
    local action="${1:-install}"

    case "$action" in
    "install")
        check_prerequisites
        detect_shell
        create_bin_directory
        download_and_install_scripts
        update_path
        test_installation

        echo ""
        log_success "BAMP installation complete! ${ROCKET}"
        echo ""
        log_info "Next steps:"
        echo "  1. Restart your terminal or run: ${CYAN}source $PROFILE_FILE${NC}"
        echo "  2. Try: ${CYAN}bamp --help${NC}"
        echo "  3. Install your development stack: ${CYAN}bamp${NC}"
        echo ""
        log_info "Your BAMP development environment is ready! ${BEER}"
        ;;

    "uninstall")
        detect_shell
        uninstall_bamp
        ;;

    "--help" | "-h" | "help")
        show_usage
        ;;

    *)
        log_error "Unknown option: $action"
        echo ""
        show_usage
        exit 1
        ;;
    esac
}

# Run main function with all arguments
main "$@"
