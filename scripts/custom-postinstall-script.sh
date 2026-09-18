#!/bin/bash
# custom-postinstall-script.sh - Run a user-supplied CUSTOM_POSTINSTALL_SCRIPT at the end of `make all`
#
# CUSTOM_POSTINSTALL_SCRIPT is a command line: the first token is the script to
# run, and any remaining tokens are passed to it as arguments. The script may be:
#
#   - A local file path:
#       CUSTOM_POSTINSTALL_SCRIPT="/home/user/bla/thescript.sh arg1 arg2"
#   - An http(s) URL, which is downloaded and chmod +x'd into a gitignored dir
#     before being run:
#       CUSTOM_POSTINSTALL_SCRIPT="https://example.com/thescript.sh arg1 arg2"
#
# Empty (the default) means there is nothing to run, so this is a no-op.

# Exit on error and catch pipe failures
set -e
set -o pipefail

# Source common utilities and configuration
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# Directory where http(s) scripts are downloaded (under the gitignored repos/ dir).
CUSTOM_POSTINSTALL_SCRIPT_DIR=${CUSTOM_POSTINSTALL_SCRIPT_DIR:-"repos/custom-post-install"}

function run_custom_postinstall_script() {
    if [ -z "${CUSTOM_POSTINSTALL_SCRIPT:-}" ]; then
        log "INFO" "CUSTOM_POSTINSTALL_SCRIPT is empty, nothing to run."
        return 0
    fi

    # Split the command line: first token is the script, the rest are its args.
    local parts
    read -r -a parts <<< "$CUSTOM_POSTINSTALL_SCRIPT"
    local script="${parts[0]}"
    local args=("${parts[@]:1}")

    local runnable
    if [[ "$script" =~ ^https?:// ]]; then
        mkdir -p "$CUSTOM_POSTINSTALL_SCRIPT_DIR"
        runnable="${CUSTOM_POSTINSTALL_SCRIPT_DIR}/$(basename "$script")"
        log "INFO" "Downloading custom post-install script from $script"
        retry 3 10 curl -fsSL "$script" -o "$runnable"
        chmod +x "$runnable"
    else
        runnable="$script"
        if [ ! -f "$runnable" ]; then
            log "ERROR" "CUSTOM_POSTINSTALL_SCRIPT file not found: $runnable"
            return 1
        fi
    fi

    log "INFO" "Running custom post-install script: $runnable ${args[*]}"
    "$runnable" "${args[@]}"
    log "INFO" "Custom post-install script completed."
}

# If script is executed directly (not sourced), run the appropriate function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        log "ERROR" "Usage: $0 <run>"
        exit 1
    fi

    case "$1" in
        run)
            run_custom_postinstall_script
            ;;
        *)
            log "ERROR" "Unknown command: $1"
            log "ERROR" "Available commands: run"
            exit 1
            ;;
    esac
fi
