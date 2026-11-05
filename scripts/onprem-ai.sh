#!/bin/bash
# onprem-ai.sh - On-prem Assisted Installer deployment
#
# Deploys a local Assisted Installer instance using aicli, enabling
# cluster installation with custom OCP release payloads.

# Exit on error and catch pipe failures
set -e
set -o pipefail

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

function deploy_onprem_ai() {
    if podman pod exists assisted-installer 2>/dev/null \
        && curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:8888/health >/dev/null 2>&1; then
        local _versions
        _versions=$(curl -sf --connect-timeout 3 --max-time 5 \
            http://127.0.0.1:8090/api/assisted-install/v2/openshift-versions)
        if echo "${_versions}" | grep -q "${PAYLOAD_URL}"; then
            log "INFO" "On-prem Assisted Installer is already running with the expected release image, skipping deployment"
            return 0
        fi
        log "INFO" "Running Assisted Installer has a different release image, redeploying..."
    fi
    if podman pod exists assisted-installer 2>/dev/null; then
        log "INFO" "Removing previous on-prem Assisted Installer pod..."
        podman pod rm -f assisted-installer
    fi
    log "INFO" "Using aicli from: $(which aicli)"
    log "INFO" "Deploying on-prem Assisted Installer with release image ${PAYLOAD_URL}..."
    local _short_version="${OPENSHIFT_VERSION%%.*}.$(echo "$OPENSHIFT_VERSION" | cut -d. -f2)"

    # When AI_URL points to a remote host (e.g. Prow deploying through an SSH
    # tunnel), pass the host and port overrides so aicli configures
    # SERVICE_BASE_URL for remote VMs to phone home correctly.
    local _onprem_args=()
    if [[ "${AI_URL}" != *"127.0.0.1"* ]] && [[ "${AI_URL}" != *"localhost"* ]]; then
        local _ai_host
        _ai_host=$(echo "${AI_URL}" | sed 's|http[s]*://||' | cut -d: -f1)
        _onprem_args+=(-P "onprem_ip=${_ai_host}")
    fi
    if [[ -n "${AI_ONPREM_PORT:-}" ]]; then
        _onprem_args+=(-P "onprem_port=${AI_ONPREM_PORT}")
    fi
    if [[ -n "${AI_ONPREM_IMAGE_PORT:-}" ]]; then
        _onprem_args+=(-P "onprem_image_port=${AI_ONPREM_IMAGE_PORT}")
    fi

    aicli create onprem \
        -P ocp_release_image="${PAYLOAD_URL}" \
        -P openshift_version="${_short_version}" \
        -P version_long="${OPENSHIFT_VERSION}" \
        -P installer_registry="quay.io" \
        "${_onprem_args[@]}"
    log "INFO" "Waiting for on-prem Assisted Installer to be ready..."
    retry 30 2 --no-dump-on-failure curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:8888/health
    log "INFO" "On-prem Assisted Installer is ready"
}

# If script is executed directly (not sourced), run deploy_onprem_ai
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_onprem_ai "$@"
fi
