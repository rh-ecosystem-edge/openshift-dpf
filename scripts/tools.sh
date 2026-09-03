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

# Prefer MCE_OPERATOR_CHANNEL (default stable-2.17) when that channel exists in
# the catalog the subscription will use. Otherwise use PackageManifest defaultChannel.
function resolve_mce_operator_channel() {
    local catalog="${CATALOG_SOURCE_NAME:-redhat-operators}"
    local requested="${MCE_OPERATOR_CHANNEL:-stable-2.17}"
    local pm_json=""
    local default_channel=""
    local available=""
    local attempt=0
    local retries=12
    local delay=5

    log "INFO" "Looking up MCE PackageManifest in catalog ${catalog} (requested channel ${requested})..."
    while (( attempt < retries )); do
        pm_json=$(oc get packagemanifests -n openshift-marketplace -o json 2>/dev/null | \
            jq -c --arg cat "${catalog}" '
                .items[] | select(.metadata.name=="multicluster-engine" and .status.catalogSource==$cat)
            ' | head -n1)
        if [ -n "${pm_json}" ]; then
            break
        fi
        attempt=$((attempt + 1))
        log "INFO" "PackageManifest not ready yet (attempt ${attempt}/${retries}). Retrying in ${delay}s..."
        sleep "${delay}"
    done

    if [ -z "${pm_json}" ] && [ "${catalog}" != "redhat-operators" ]; then
        log "WARN" "multicluster-engine not found in ${catalog}; trying redhat-operators"
        catalog="redhat-operators"
        pm_json=$(oc get packagemanifests -n openshift-marketplace -o json 2>/dev/null | \
            jq -c --arg cat "${catalog}" '
                .items[] | select(.metadata.name=="multicluster-engine" and .status.catalogSource==$cat)
            ' | head -n1)
    fi

    if [ -z "${pm_json}" ]; then
        log "ERROR" "No multicluster-engine PackageManifest found in catalog ${catalog}"
        oc get packagemanifests -n openshift-marketplace \
            -o custom-columns=NAME:.metadata.name,CATALOG:.status.catalogSource,DEFAULT:.status.defaultChannel \
            2>/dev/null | grep -E 'NAME|multicluster-engine' || true
        return 1
    fi

    MCE_CATALOG_SOURCE="${catalog}"
    default_channel=$(echo "${pm_json}" | jq -r '.status.defaultChannel // empty')
    available=$(echo "${pm_json}" | jq -r '[.status.channels[].name] | join(" ")')
    log "INFO" "Catalog ${catalog} MCE defaultChannel=${default_channel} channels=[${available}]"

    if echo "${pm_json}" | jq -e --arg ch "${requested}" '.status.channels[] | select(.name==$ch)' >/dev/null; then
        MCE_OPERATOR_CHANNEL="${requested}"
        log "INFO" "Using requested MCE channel ${MCE_OPERATOR_CHANNEL}"
        return 0
    fi

    if [ -n "${default_channel}" ]; then
        log "WARN" "Requested MCE channel ${requested} is not in catalog ${catalog}; using defaultChannel ${default_channel}"
        MCE_OPERATOR_CHANNEL="${default_channel}"
        return 0
    fi

    log "ERROR" "Could not resolve MCE channel from catalog ${catalog}. Available: ${available}"
    return 1
}

function install_hypershift_via_mce() {
    log "INFO" "Installing Hypershift via MultiCluster Engine (MCE)..."

    local manifests_dir="${MANIFESTS_DIR:-manifests}"
    local generated_dir="${GENERATED_DIR:-manifests/generated}"
    mkdir -p "${generated_dir}"

    resolve_mce_operator_channel || return 1

    # Always apply so a previously-wrong channel (e.g. stable-2.7) is updated.
    log "INFO" "Deploying MCE operator subscription (channel ${MCE_OPERATOR_CHANNEL}, catalog ${MCE_CATALOG_SOURCE})..."
    process_template \
        "${manifests_dir}/mce/mce-subscription.yaml" \
        "${generated_dir}/mce-subscription.yaml" \
        "<CATALOG_SOURCE_NAME>" "${MCE_CATALOG_SOURCE}" \
        "<MCE_OPERATOR_CHANNEL>" "${MCE_OPERATOR_CHANNEL}"

    apply_manifest "${generated_dir}/mce-subscription.yaml" true

    # Wait for the operator to be running before creating the MCE instance.
    log "INFO" "Waiting for MultiCluster Engine operator CSV to succeed..."
    if ! retry 60 10 bash -c 'oc get csv -n multicluster-engine -o jsonpath="{.items[*].status.phase}" 2>/dev/null | grep -q "Succeeded"'; then
        log "ERROR" "Timeout: MCE operator CSV did not reach Succeeded phase"
        oc get csv -n multicluster-engine 2>/dev/null || true
        return 1
    fi
    log "INFO" "Waiting for MultiClusterEngine CRD..."
    if ! retry 30 5 oc get crd multiclusterengines.multicluster.openshift.io &>/dev/null; then
        log "ERROR" "Timeout: MultiClusterEngine CRD is not available"
        return 1
    fi
    # CSV/CRD can exist before the validating webhook has endpoints.
    log "INFO" "Waiting for MCE validating webhook endpoints..."
    if ! retry 24 5 bash -c 'oc get endpoints -n multicluster-engine multicluster-engine-operator-webhook-service -o jsonpath="{.subsets[*].addresses[*].ip}" 2>/dev/null | grep -q "[0-9]"'; then
        log "WARN" "Webhook endpoints not ready after 2 minutes; will retry creating the MultiClusterEngine CR"
    fi
    log "INFO" "MCE operator is running"

    # One MultiClusterEngine per cluster. Reuse an existing instance if present.
    local mce_name
    mce_name=$(oc get multiclusterengine -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${mce_name}" ]; then
        log "INFO" "MultiClusterEngine ${mce_name} already exists. Ensuring hypershift is enabled..."
        if ! retry 24 5 oc patch multiclusterengine "${mce_name}" --type=merge \
            -p '{"spec":{"overrides":{"components":[{"name":"hypershift","enabled":true}]}}}' ; then
            log "ERROR" "Failed to patch MultiClusterEngine ${mce_name} after retries"
            return 1
        fi
    else
        mce_name="mce"
        log "INFO" "Creating MultiClusterEngine ${mce_name} with hypershift enabled..."
        if ! retry 24 5 oc apply -f "${manifests_dir}/mce/multiclusterengine.yaml"; then
            log "ERROR" "Failed to create MultiClusterEngine ${mce_name} after retries (webhook may still be unavailable)"
            return 1
        fi
    fi

    log "INFO" "Waiting for MultiClusterEngine ${mce_name} to become Available..."
    if ! retry 90 10 bash -c "oc get multiclusterengine ${mce_name} -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Available"; then
        log "ERROR" "Timeout: MultiClusterEngine ${mce_name} did not reach Available status"
        oc get multiclusterengine "${mce_name}" 2>/dev/null || true
        oc get multiclusterengine "${mce_name}" -o yaml 2>/dev/null || true
        return 1
    fi
    oc get multiclusterengine "${mce_name}"

    local hs_enabled
    hs_enabled=$(oc get multiclusterengine "${mce_name}" \
        -o jsonpath='{.spec.overrides.components[?(@.name=="hypershift")].enabled}' 2>/dev/null || true)
    if [ "${hs_enabled}" != "true" ]; then
        log "ERROR" "HyperShift is not enabled on MultiClusterEngine ${mce_name} (got '${hs_enabled}')"
        return 1
    fi
    log "INFO" "HyperShift component is enabled on MultiClusterEngine ${mce_name}"

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
        deploy-mce|install-hypershift-mce)
            install_hypershift_via_mce
            ;;
        *)
            log "Unknown command: $command"
            log "Available commands: install-helm, install-hypershift, deploy-mce, install-hypershift-mce"
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
