#!/bin/bash
# tools.sh - Tool installation and management

# Exit on error
set -e

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# -----------------------------------------------------------------------------
# Tool installation functions
# -----------------------------------------------------------------------------
function ensure_helm_installed() {
    if ! command -v helm &> /dev/null; then
        log "INFO" "Helm not found. Installing helm..."
        install_helm
    else
        log "INFO" "Helm is already installed. Version: $(helm version --short)"
    fi
}

function install_helm() {
    log "INFO" "Installing Helm $(if [ -n "$HELM_VERSION" ]; then echo $HELM_VERSION; else echo "latest"; fi)..."
    
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    DESIRED_VERSION=$HELM_VERSION ./get_helm.sh
    rm get_helm.sh

    log "INFO" "Helm installation complete. Installed version: $(helm version --short)"
}

function install_hypershift() {
    log "INFO" "Installing Hypershift binary and operator..."

    if command -v hypershift &>/dev/null; then
        log "INFO" "hypershift binary already installed at $(command -v hypershift), skipping binary install."
    else
        CONTAINER_COMMAND=${CONTAINER_COMMAND:-podman}
        HYPERSHIFT_REPO=${HYPERSHIFT_REPO:-https://github.com/openshift/hypershift.git}

        # Try extracting the binary from the container image first.
        # Falls back to building from source if the image doesn't match the host architecture.
        PULL_OUTPUT=$($CONTAINER_COMMAND cp $($CONTAINER_COMMAND create --name hypershift --rm --pull always $HYPERSHIFT_IMAGE):/usr/bin/hypershift /tmp/hypershift 2>&1) && PULL_RC=0 || PULL_RC=$?
        if [ $PULL_RC -eq 0 ]; then
            $CONTAINER_COMMAND rm -f hypershift
            log "INFO" "Extracted hypershift binary from container image."
        elif echo "$PULL_OUTPUT" | grep -q "no image found in manifest list for architecture"; then
            $CONTAINER_COMMAND rm -f hypershift 2>/dev/null || true
            log "WARN" "Image $HYPERSHIFT_IMAGE not available for $(uname -m). Building from source..."

            if ! command -v go &>/dev/null; then
                log "ERROR" "Go toolchain not found. Install Go >= 1.22 and retry."
                return 1
            fi

            HYPERSHIFT_BUILD_DIR=$(mktemp -d)
            trap "rm -rf $HYPERSHIFT_BUILD_DIR" RETURN
            git clone --depth 1 "$HYPERSHIFT_REPO" "$HYPERSHIFT_BUILD_DIR"
            pushd "$HYPERSHIFT_BUILD_DIR" > /dev/null
            go build -o /tmp/hypershift .
            popd > /dev/null
            log "INFO" "Built hypershift binary from source for $(uname -m)."
        else
            log "ERROR" "Failed to extract hypershift binary: $PULL_OUTPUT"
            return 1
        fi

        install -m 0755 /tmp/hypershift "$HOME/.local/bin/hypershift"
        rm -f /tmp/hypershift
        log "INFO" "Installed hypershift binary to $HOME/.local/bin/hypershift"
    fi

    # Install the Hypershift operator
    KUBECONFIG=$KUBECONFIG hypershift install --hypershift-image $HYPERSHIFT_IMAGE

    # Check the Hypershift operator status
    log "INFO" "Checking Hypershift operator status..."
    KUBECONFIG=$KUBECONFIG oc -n hypershift get pods

    log "INFO" "Hypershift installation completed successfully!"
}

function install_oc() {
    # Download the OpenShift CLI
    log "INFO" "Downloading OpenShift CLI..."
    wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz

    # Extract the archive
    tar -xzf openshift-client-linux.tar.gz

    # Move the oc binary to a directory in your PATH
    sudo mv oc /usr/local/bin/

    # Verify the installation
    oc version
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
function main() {
    local command=$1
    shift

    case "$command" in
        install-helm)
            install_helm
            ;;
        install-hypershift)
            install_hypershift
            ;;
        *)
            log "Unknown command: $command"
            log "Available commands: install-helm, install-hypershift"
            exit 1
            ;;
    esac
}

# If script is executed directly (not sourced), run the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        log "Usage: $0 <command> [arguments...]"
        exit 1
    fi
    
    main "$@"
fi 
