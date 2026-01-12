#!/bin/bash
# worker.sh - Worker node provisioning via BMO/Redfish

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/cluster.sh"

# Use existing path conventions from env.sh
WORKER_TEMPLATE_DIR="${MANIFESTS_DIR}/worker-provisioning"
WORKER_GENERATED_DIR="${GENERATED_DIR}/worker-provisioning"


provision_all_workers() {
    local count="${WORKER_COUNT:-0}"
    [[ "$count" -eq 0 ]] && { log "INFO" "WORKER_COUNT=0, skipping"; return 0; }

    # Ensure kubeconfig is available
    get_kubeconfig

    # Apply short worker hostnames MachineConfig if enabled
    apply_short_worker_hostnames

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
            "<ROOT_DEVICE>" "$root_dev"

        # Apply manifests
        apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmc-secret.yaml" false
        apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" false
        log "INFO" "BMH $name created"
    done

    log "INFO" "Worker provisioning initiated"
}

approve_worker_csrs() {
    get_kubeconfig
    # Approve all pending CSRs - simple and effective for worker provisioning
    # OpenShift's cluster-machine-approver handles normal CSR approval,
    # but we need to approve CSRs for BMO-provisioned workers manually
    local approved=0
    local csr

    for csr in $(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null); do
        if oc adm certificate approve "$csr" 2>/dev/null; then
            log "INFO" "Approved CSR $csr"
            ((approved++)) || true
        fi
    done

    [[ $approved -gt 0 ]] && log "INFO" "Approved $approved CSR(s)" || true
}

is_worker_registered() {
    # Check if worker's BMH is in provisioned state
    # This means the worker has been fully provisioned and should be a node
    local bmh_name="$1"

    # Check BMH provisioning state - if "provisioned", the worker is done
    local bmh_state
    bmh_state=$(oc get bmh -n openshift-machine-api "$bmh_name" \
        -o jsonpath='{.status.provisioning.state}' 2>/dev/null)
    [[ "$bmh_state" == "provisioned" ]] && return 0

    return 1
}

wait_and_approve_csrs() {
    get_kubeconfig
    local timeout="${CSR_APPROVAL_TIMEOUT:-600}"
    local count="${WORKER_COUNT:-0}"
    local end=$((SECONDS + timeout))

    # Check if all workers already registered (skip wait if so)
    local ready=0
    for i in $(seq 1 "$count"); do
        local name_var="WORKER_${i}_NAME"
        local bmh_name="${!name_var}"
        is_worker_registered "$bmh_name" && ((ready++)) || true
    done
    [[ "$ready" -ge "$count" ]] && { log "INFO" "All $count workers already registered, skipping CSR wait"; return 0; }

    log "INFO" "Waiting for CSRs (timeout: ${timeout}s)..."

    while [[ $SECONDS -lt $end ]]; do
        approve_worker_csrs

        # Check if all workers registered
        local ready=0
        for i in $(seq 1 "$count"); do
            local name_var="WORKER_${i}_NAME"
            local bmh_name="${!name_var}"
            is_worker_registered "$bmh_name" && ((ready++)) || true
        done

        [[ "$ready" -ge "$count" ]] && { log "INFO" "All $count workers registered"; return 0; }
        sleep 30
    done

    log "WARN" "Timeout - some workers may need manual CSR approval"
}

display_worker_status() {
    get_kubeconfig
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

apply_short_worker_hostnames() {
    # Apply MachineConfig that sets worker hostnames based on MAC address
    # This is controlled by ENABLE_SHORT_WORKER_HOSTNAMES flag
    if [[ "${ENABLE_SHORT_WORKER_HOSTNAMES}" != "true" ]]; then
        log "INFO" "ENABLE_SHORT_WORKER_HOSTNAMES is not set to true, skipping short hostname MachineConfig"
        return 0
    fi

    get_kubeconfig

    local manifest="${WORKER_TEMPLATE_DIR}/99-short-worker-hostnames.yaml"
    if [[ ! -f "$manifest" ]]; then
        log "ERROR" "Short worker hostnames manifest not found: $manifest"
        return 1
    fi

    log "INFO" "Applying short worker hostnames MachineConfig..."
    apply_manifest "$manifest" false
    log "INFO" "Short worker hostnames MachineConfig applied successfully"
}

# Command dispatcher
case "${1:-}" in
    provision-all-workers) provision_all_workers ;;
    approve-worker-csrs) approve_worker_csrs ;;
    wait-and-approve-csrs) wait_and_approve_csrs ;;
    display-worker-status) display_worker_status ;;
    display-manual-csr-instructions) display_manual_csr_instructions ;;
    apply-short-worker-hostnames) apply_short_worker_hostnames ;;
    *)
        echo "Usage: $0 {provision-all-workers|approve-worker-csrs|wait-and-approve-csrs|display-worker-status|display-manual-csr-instructions|apply-short-worker-hostnames}"
        exit 1
        ;;
esac
