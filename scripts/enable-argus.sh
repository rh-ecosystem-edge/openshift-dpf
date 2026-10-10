#!/bin/bash
# Install or update the DOCA Argus service without applying other DPU manifests.

set -e
set -o pipefail

if ! declare -F get_kubeconfig >/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"
fi

MANIFESTS_DIR=${MANIFESTS_DIR:-"manifests"}
GENERATED_DIR=${GENERATED_DIR:-"${MANIFESTS_DIR}/generated"}
GENERATED_POST_INSTALL_DIR=${GENERATED_POST_INSTALL_DIR:-"${GENERATED_DIR}/post-install"}

function render_argus_manifests() {
    local template_src="${MANIFESTS_DIR}/argus/01-servicetemplate.yaml"
    local config_src="${MANIFESTS_DIR}/argus/02-configuration.yaml"
    local template_dst="${GENERATED_POST_INSTALL_DIR}/argus-01-servicetemplate.yaml"
    local config_dst="${GENERATED_POST_INSTALL_DIR}/argus-02-configuration.yaml"

    mkdir -p "${GENERATED_POST_INSTALL_DIR}"
    update_file_multi_replace "${template_src}" "${template_dst}" \
        "<ARGUS_HELM_REPO_URL>" "${ARGUS_HELM_REPO_URL}" \
        "<ARGUS_CHART_VERSION>" "${ARGUS_CHART_VERSION}"
    update_file_multi_replace "${config_src}" "${config_dst}" \
        "<ARGUS_IMAGE>" "${ARGUS_IMAGE}"
}

function apply_argus_manifests() {
    log "INFO" "Applying Argus DPUServiceTemplate and DPUServiceConfiguration..."
    retry 5 30 apply_manifest "${GENERATED_POST_INSTALL_DIR}/argus-01-servicetemplate.yaml" "true"
    retry 5 30 apply_manifest "${GENERATED_POST_INSTALL_DIR}/argus-02-configuration.yaml" "true"
}

function patch_argus_service() {
    oc patch dpudeployment dpudeployment -n dpf-operator-system --type=merge \
        -p '{"spec":{"services":{"argus":{"serviceTemplate":"argus","serviceConfiguration":"argus"}}}}'
}

function enable_argus() {
    get_kubeconfig
    if ! oc get dpudeployment dpudeployment -n dpf-operator-system >/dev/null 2>&1; then
        log "ERROR" "DPUDeployment dpudeployment was not found. Deploy DPU services before running make enable-argus."
        return 1
    fi

    render_argus_manifests
    apply_argus_manifests

    log "INFO" "Adding Argus to DPUDeployment dpudeployment..."
    patch_argus_service
    log "INFO" "Argus service enabled"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-enable}" in
        enable)
            require_argus_enabled
            enable_argus
            ;;
        *)
            log "ERROR" "Unknown command: ${1}"
            exit 1
            ;;
    esac
fi
