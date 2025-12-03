#!/bin/bash
# worker.sh - Worker node provisioning via BMO/Redfish

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

# Use existing path conventions from env.sh
WORKER_TEMPLATE_DIR="${MANIFESTS_DIR}/worker-provisioning"
WORKER_GENERATED_DIR="${GENERATED_DIR}/worker-provisioning"

provision_all_workers() {
    local count="${WORKER_COUNT:-0}"
    [[ "$count" -eq 0 ]] && { log "INFO" "WORKER_COUNT=0, skipping"; return 0; }

    # BMO is pre-installed in OpenShift - verify it's available
    if ! oc get clusteroperator baremetal &>/dev/null; then
        log "ERROR" "Baremetal cluster operator not found. This should not happen in OpenShift."
        return 1
    fi

    # Ensure Provisioning CR exists (apply_manifest handles existence check)
    apply_manifest "${WORKER_TEMPLATE_DIR}/provisioning.yaml" false

    mkdir -p "${WORKER_GENERATED_DIR}"
    log "INFO" "Provisioning ${count} worker(s)..."

    for i in $(seq 1 "$count"); do
        local name_var="WORKER_${i}_NAME"
        local name="${!name_var}"
        [[ -z "$name" ]] && { log "ERROR" "${name_var} not set"; return 1; }

        # Skip if already exists (idempotent)
        if oc get bmh -n openshift-machine-api "$name" &>/dev/null; then
            log "INFO" "BMH $name already exists, skipping"
            continue
        fi

        # Get worker config via indirect expansion
        local bmc_ip_var="WORKER_${i}_BMC_IP"; local bmc_ip="${!bmc_ip_var}"
        local bmc_user_var="WORKER_${i}_BMC_USER"; local bmc_user="${!bmc_user_var}"
        local bmc_pass_var="WORKER_${i}_BMC_PASSWORD"; local bmc_pass="${!bmc_pass_var}"
        local boot_mac_var="WORKER_${i}_BOOT_MAC"; local boot_mac="${!boot_mac_var}"
        local root_dev_var="WORKER_${i}_ROOT_DEVICE"; local root_dev="${!root_dev_var:-/dev/sda}"

        # Validate required vars
        [[ -z "$bmc_ip" ]] && { log "ERROR" "WORKER_${i}_BMC_IP not set"; return 1; }
        [[ -z "$bmc_user" ]] && { log "ERROR" "WORKER_${i}_BMC_USER not set"; return 1; }
        [[ -z "$bmc_pass" ]] && { log "ERROR" "WORKER_${i}_BMC_PASSWORD not set"; return 1; }
        [[ -z "$boot_mac" ]] && { log "ERROR" "WORKER_${i}_BOOT_MAC not set"; return 1; }

        log "INFO" "Creating manifests for $name..."

        # Generate BMC secret using process_template
        process_template \
            "${WORKER_TEMPLATE_DIR}/bmc-secret.yaml" \
            "${WORKER_GENERATED_DIR}/${name}-bmc-secret.yaml" \
            "<WORKER_NAME>" "$name" \
            "<BMC_USER_BASE64>" "$(printf '%s' "$bmc_user" | base64)" \
            "<BMC_PASSWORD_BASE64>" "$(printf '%s' "$bmc_pass" | base64)"

        # Generate BareMetalHost using process_template
        process_template \
            "${WORKER_TEMPLATE_DIR}/baremetalhost.yaml" \
            "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" \
            "<WORKER_NAME>" "$name" \
            "<BOOT_MAC>" "$boot_mac" \
            "<BMC_IP>" "$bmc_ip" \
            "<ROOT_DEVICE>" "$root_dev" \

        # Apply manifests
        apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmc-secret.yaml" false
        apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" false
        log "INFO" "BMH $name created"
    done

    log "INFO" "Worker provisioning initiated"
}

approve_worker_csrs() {
    local count="${WORKER_COUNT:-0}"

    # Get worker names to match
    local -a workers=()
    for i in $(seq 1 "$count"); do
        local name_var="WORKER_${i}_NAME"
        local name="${!name_var}"
        [[ -n "$name" ]] && workers+=("$name")
    done

    # Approve matching pending CSRs
    local username pending
    pending=$(oc get csr --no-headers 2>/dev/null | grep Pending || true)
    [[ -z "$pending" ]] && return 0

    while read -r csr _; do
        username=$(oc get csr "$csr" -o jsonpath='{.spec.username}' 2>/dev/null)
        for w in "${workers[@]}"; do
            if [[ "$username" == "system:node:$w" ]]; then
                oc adm certificate approve "$csr" && log "INFO" "Approved CSR $csr for $w"
                break
            fi
        done
    done <<< "$pending"
}

wait_and_approve_csrs() {
    local timeout="${CSR_APPROVAL_TIMEOUT:-600}"
    local count="${WORKER_COUNT:-0}"
    local end=$((SECONDS + timeout))

    log "INFO" "Waiting for CSRs (timeout: ${timeout}s)..."

    while [[ $SECONDS -lt $end ]]; do
        approve_worker_csrs

        # Check if all workers registered
        local ready=0
        for i in $(seq 1 "$count"); do
            local name_var="WORKER_${i}_NAME"
            local name="${!name_var}"
            oc get node "$name" &>/dev/null && ((ready++))
        done

        [[ "$ready" -ge "$count" ]] && { log "INFO" "All $count workers registered"; return 0; }
        sleep 30
    done

    log "WARN" "Timeout - some workers may need manual CSR approval"
}

display_worker_status() {
    echo "=== Worker Status ==="
    oc get bmh -n openshift-machine-api
    echo ""
    echo "=== Nodes ==="
    oc get nodes
}

display_manual_csr_instructions() {
    echo ""
    echo "To approve CSRs manually:"
    echo "  oc get csr | grep Pending"
    echo "  oc adm certificate approve <csr-name>"
    echo "Or: make approve-worker-csrs"
}

# Command dispatcher
case "${1:-}" in
    provision-all-workers) provision_all_workers ;;
    approve-worker-csrs) approve_worker_csrs ;;
    wait-and-approve-csrs) wait_and_approve_csrs ;;
    display-worker-status) display_worker_status ;;
    display-manual-csr-instructions) display_manual_csr_instructions ;;
    *)
        echo "Usage: $0 {provision-all-workers|approve-worker-csrs|wait-and-approve-csrs|display-worker-status|display-manual-csr-instructions}"
        exit 1
        ;;
esac
