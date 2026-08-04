#!/bin/bash
# tools.sh - Tool installation and management

# Exit on error
set -e

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

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

function extract_hypershift_binary() {
    CONTAINER_COMMAND=${CONTAINER_COMMAND:-podman}
    "$CONTAINER_COMMAND" cp "$("$CONTAINER_COMMAND" create --name hypershift --rm --pull always "$HYPERSHIFT_IMAGE"):/usr/bin/hypershift" /tmp/hypershift 2>&1
    local rc=$?
    "$CONTAINER_COMMAND" rm -f hypershift 2>/dev/null || true
    return $rc
}

function build_hypershift_from_source() {
    HYPERSHIFT_REPO=${HYPERSHIFT_REPO:-https://github.com/openshift/hypershift.git}

    if ! command -v go &>/dev/null; then
        log "ERROR" "Go toolchain not found. Install Go >= 1.22 and retry."
        return 1
    fi

    local build_dir
    build_dir=$(mktemp -d)
    trap "rm -rf $build_dir" RETURN
    git clone --depth 1 "$HYPERSHIFT_REPO" "$build_dir"
    pushd "$build_dir" > /dev/null
    go build -o /tmp/hypershift .
    popd > /dev/null
    log "INFO" "Built hypershift binary from source for $(uname -m)."
}

function install_hypershift() {
    log "INFO" "Installing Hypershift binary and operator..."

    if [[ "$(uname -m)" == "x86_64" ]]; then
        if ! extract_hypershift_binary; then
            log "ERROR" "Failed to extract hypershift binary from container image"
            return 1
        fi
        log "INFO" "Extracted hypershift binary from container image."
    else
        log "INFO" "Non-x86 host ($(uname -m)), building hypershift from source..."
        if ! build_hypershift_from_source; then
            log "ERROR" "Failed to build hypershift from source"
            return 1
        fi
    fi

    mkdir -p "$HOME/.local/bin"
    install -m 0755 /tmp/hypershift "$HOME/.local/bin/hypershift"
    rm -f /tmp/hypershift
    log "INFO" "Installed hypershift binary to $HOME/.local/bin/hypershift"

    # Install the Hypershift operator
    KUBECONFIG=$KUBECONFIG hypershift install --hypershift-image $HYPERSHIFT_IMAGE

    # Check the Hypershift operator status
    log "INFO" "Checking Hypershift operator status..."
    KUBECONFIG=$KUBECONFIG oc -n hypershift get pods

    log "INFO" "Hypershift installation completed successfully!"
}

function install_hypershift_via_mce() {
    log "INFO" "Installing Hypershift via MultiCluster Engine (MCE)..."

    local manifests_dir="${MANIFESTS_DIR:-manifests}"
    local generated_dir="${GENERATED_DIR:-manifests/generated}"
    mkdir -p "${generated_dir}"

    # Step 1: Deploy MCE operator subscription
    if oc get subscription -n multicluster-engine multicluster-engine &>/dev/null; then
        log "INFO" "MCE subscription already exists. Skipping subscription deployment."
    else
        log "INFO" "Deploying MCE operator subscription..."
        process_template \
            "${manifests_dir}/mce/mce-subscription.yaml" \
            "${generated_dir}/mce-subscription.yaml" \
            "<CATALOG_SOURCE_NAME>" "${CATALOG_SOURCE_NAME}"

        apply_manifest "${generated_dir}/mce-subscription.yaml" true
    fi

    # Step 2: Wait for MCE operator CSV to succeed
    log "INFO" "Waiting for MultiCluster Engine operator to be ready..."
    if ! retry 60 10 bash -c 'oc get csv -n multicluster-engine -o jsonpath="{.items[*].status.phase}" 2>/dev/null | grep -q "Succeeded"'; then
        log "ERROR" "Timeout: MCE operator CSV did not reach Succeeded phase"
        return 1
    fi
    log "INFO" "MCE operator is ready"

    # Step 3: Create MultiClusterEngine instance with hypershift enabled
    if oc get multiclusterengine multiclusterengine &>/dev/null; then
        log "INFO" "MultiClusterEngine instance already exists. Ensuring hypershift is enabled..."
        oc patch multiclusterengine multiclusterengine --type=merge \
            -p '{"spec":{"overrides":{"components":[{"name":"hypershift","enabled":true}]}}}'
    else
        log "INFO" "Creating MultiClusterEngine instance with hypershift enabled..."
        apply_manifest "${manifests_dir}/mce/multiclusterengine.yaml" true
    fi

    # Step 4: Wait for MultiClusterEngine to become Available
    log "INFO" "Waiting for MultiClusterEngine to become Available..."
    if ! retry 60 10 bash -c 'oc get multiclusterengine multiclusterengine -o jsonpath="{.status.phase}" 2>/dev/null | grep -q "Available"'; then
        log "ERROR" "Timeout: MultiClusterEngine did not reach Available status"
        oc get multiclusterengine multiclusterengine -o yaml 2>/dev/null || true
        return 1
    fi
    log "INFO" "MultiClusterEngine is Available"

    # Step 5: Verify hypershift operator pods are running
    log "INFO" "Waiting for Hypershift operator pods (deployed by MCE)..."
    if ! retry 30 10 bash -c 'oc get pods -n hypershift -l app=operator --no-headers 2>/dev/null | grep -q "Running"'; then
        log "WARN" "Hypershift operator pods not yet running in hypershift namespace, checking multicluster-engine namespace..."
        if ! retry 15 10 bash -c 'oc get pods -n multicluster-engine -l app=operator --no-headers 2>/dev/null | grep -q "Running"'; then
            log "ERROR" "Hypershift operator pods not found in either namespace"
            return 1
        fi
    fi

    log "INFO" "Hypershift installation via MCE completed successfully!"
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
        install-hypershift-mce)
            install_hypershift_via_mce
            ;;
        *)
            log "Unknown command: $command"
            log "Available commands: install-helm, install-hypershift, install-hypershift-mce"
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
