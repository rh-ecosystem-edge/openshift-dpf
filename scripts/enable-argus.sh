#!/bin/bash
# Install or update the DOCA Argus service without applying other DPU manifests.

set -e
set -o pipefail

MANIFESTS_DIR=${MANIFESTS_DIR:-"manifests"}
GENERATED_DIR=${GENERATED_DIR:-"$MANIFESTS_DIR/generated"}
GENERATED_POST_INSTALL_DIR="${GENERATED_POST_INSTALL_DIR:-"${GENERATED_DIR}/post-install"}"

if ! declare -F get_kubeconfig >/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"
fi

function render_argus_manifests() {
    local template_src="${MANIFESTS_DIR}/argus/01-servicetemplate.yaml"
    local config_src="${MANIFESTS_DIR}/argus/02-configuration.yaml"
    local template_dst="${GENERATED_POST_INSTALL_DIR}/argus-01-servicetemplate.yaml"
    local config_dst="${GENERATED_POST_INSTALL_DIR}/argus-02-configuration.yaml"

    mkdir -p "${GENERATED_POST_INSTALL_DIR}"
    update_file_multi_replace "${template_src}" "${template_dst}" \
        "<ARGUS_HELM_REPO_URL>" "${ARGUS_HELM_REPO_URL}" \
        "<ARGUS_CHART_VERSION>" "${ARGUS_CHART_VERSION}" \
        "<ARGUS_IMAGE>" "${ARGUS_IMAGE}" \
        "<ARGUS_IMAGE_PULL_SECRET>" "${ARGUS_IMAGE_PULL_SECRET}"
    cp "${config_src}" "${config_dst}"
}

function apply_argus_manifests() {
    log "INFO" "Applying Argus DPUServiceTemplate and DPUServiceConfiguration..."
    retry 5 30 apply_manifest "${GENERATED_POST_INSTALL_DIR}/argus-01-servicetemplate.yaml" "true"
    retry 5 30 apply_manifest "${GENERATED_POST_INSTALL_DIR}/argus-02-configuration.yaml" "true"
}

function patch_argus_service() {
    retry 5 30 oc patch dpudeployment dpudeployment -n dpf-operator-system --type=merge \
        -p '{"spec":{"services":{"argus":{"serviceTemplate":"argus","serviceConfiguration":"argus"}}}}'
}

function wait_for_argus_dpuservices_ready() {
    local namespace="${DPF_OPERATOR_NAMESPACE:-dpf-operator-system}"
    local deployment_name="${DPU_DEPLOYMENT_NAME:-dpudeployment}"
    local parent_label="svc.dpu.nvidia.com/owned-by-dpudeployment=${namespace}_${deployment_name}"
    local service_label="svc.dpu.nvidia.com/dpudeployment-service=argus"
    local selector="${parent_label},${service_label}"
    local max_attempts="${ARGUS_DPUSERVICE_READY_MAX_ATTEMPTS:-60}"
    local delay="${ARGUS_DPUSERVICE_READY_DELAY_SECONDS:-10}"

    log "INFO" "Waiting for Argus DPUService to become Ready..."

    for i in $(seq 1 "$max_attempts"); do
        local names not_ready=0
        names=$(oc get dpuservice -n "$namespace" -l "$selector" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

        if [ -z "$names" ]; then
            log "INFO" "Argus DPUService not created yet (attempt ${i}/${max_attempts})..."
            sleep "$delay"
            continue
        fi

        local name ready
        for name in $names; do
            ready=$(oc get dpuservice -n "$namespace" "$name" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
            if [ "$ready" != "True" ]; then
                not_ready=$((not_ready + 1))
                log "INFO" "DPUService/${name} Ready=${ready:-Unknown}"
            fi
        done

        if [ "$not_ready" -eq 0 ]; then
            log "INFO" "Argus DPUService Ready: ${names}"
            oc get dpuservice -n "$namespace" -l "$selector"
            return 0
        fi

        log "INFO" "Waiting for Argus DPUService Ready (attempt ${i}/${max_attempts})..."
        sleep "$delay"
    done

    log "ERROR" "Timed out waiting for Argus DPUService to become Ready"
    oc get dpuservice -n "$namespace" -l "$selector" -o wide 2>/dev/null || true
    return 1
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
    wait_for_argus_dpuservices_ready
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
