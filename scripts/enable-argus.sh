#!/bin/bash
# Install or update the DOCA Argus service without applying other DPU manifests.

set -e
set -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/post-install.sh"

function enable_argus() {
    if [ "${ARGUS_ENABLED}" != "true" ]; then
        log "ERROR" "ARGUS_ENABLED is not true. Set ARGUS_ENABLED=true and regenerate .env before running make enable-argus."
        return 1
    fi

    get_kubeconfig
    if ! oc get dpudeployment dpudeployment -n dpf-operator-system >/dev/null 2>&1; then
        log "ERROR" "DPUDeployment dpudeployment was not found. Deploy DPU services before running make enable-argus."
        return 1
    fi

    render_argus_manifests
    log "INFO" "Applying Argus DPUServiceTemplate and DPUServiceConfiguration..."
    apply_manifest "${GENERATED_POST_INSTALL_DIR}/argus-01-servicetemplate.yaml" "true"
    apply_manifest "${GENERATED_POST_INSTALL_DIR}/argus-02-configuration.yaml" "true"

    log "INFO" "Adding Argus to DPUDeployment dpudeployment..."
    patch_argus_service
    log "INFO" "Argus service enabled"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-enable}" in
        enable)
            enable_argus
            ;;
        *)
            log "ERROR" "Unknown command: ${1}"
            exit 1
            ;;
    esac
fi
