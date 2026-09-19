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

    # Count DPU workers (used for MachineSet replica count)
    local dpu_count=0
    for i in $(seq 1 "$count"); do
        local dpu_var="WORKER_${i}_DPU"
        [[ "${!dpu_var:-true}" == "true" ]] && ((dpu_count++)) || true
    done

    # Apply short worker hostnames MachineConfig if enabled
    apply_short_worker_hostnames

    log "INFO" "Waiting for baremetal cluster operator to be available..."
    if ! retry 30 10 oc get clusteroperator baremetal &>/dev/null; then
        log "ERROR" "Baremetal cluster operator not found after 5 minutes. This should not happen in OpenShift."
        log "ERROR" "Check cluster operator status: oc get clusteroperators"
        return 1
    fi
    log "INFO" "Baremetal cluster operator is available"

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
        local dpu_var="WORKER_${i}_DPU"; local is_dpu="${!dpu_var:-true}"

        # Validate required vars
        [[ -z "$bmc_ip" ]] && { log "ERROR" "WORKER_${i}_BMC_IP not set"; return 1; }
        [[ -z "$bmc_user" ]] && { log "ERROR" "WORKER_${i}_BMC_USER not set"; return 1; }
        [[ -z "$bmc_pass" ]] && { log "ERROR" "WORKER_${i}_BMC_PASSWORD not set"; return 1; }
        [[ -z "$boot_mac" ]] && { log "ERROR" "WORKER_${i}_BOOT_MAC not set"; return 1; }

        log "INFO" "Creating manifests for $name (DPU: $is_dpu)..."

        # Generate BMC secret using process_template
        process_template \
            "${WORKER_TEMPLATE_DIR}/bmc-secret.yaml" \
            "${WORKER_GENERATED_DIR}/${name}-bmc-secret.yaml" \
            "<WORKER_NAME>" "$name" \
            "<BMC_USER_BASE64>" "$(printf '%s' "$bmc_user" | base64)" \
            "<BMC_PASSWORD_BASE64>" "$(printf '%s' "$bmc_pass" | base64)"

        local filename="baremetalhost.yaml"
        if [[ "$is_dpu" == "true" ]]; then
           filename="baremetalhost-dpu.yaml"
        fi

        # Generate BareMetalHost using appropriate template
        process_template \
            "${WORKER_TEMPLATE_DIR}/$filename" \
            "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" \
            "<WORKER_NAME>" "$name" \
            "<BOOT_MAC>" "$boot_mac" \
            "<BMC_IP>" "$bmc_ip" \
            "<ROOT_DEVICE>" "$root_dev"
	
        # Apply manifests (retry for transient API/controller or network failures)
        retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmc-secret.yaml" false
        retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" false

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

deploy_csr_auto_approver() {
    # Deploy CSR auto-approver CronJob for host cluster
    # This automatically approves CSRs for BMH-provisioned workers without Machine objects
    get_kubeconfig

    local manifest="${WORKER_TEMPLATE_DIR}/csr-auto-approver.yaml"
    if [[ ! -f "$manifest" ]]; then
        log "ERROR" "CSR auto-approver manifest not found: $manifest"
        return 1
    fi

    # Check if already deployed
    if oc get cronjob -n openshift-machine-api csr-auto-approver &>/dev/null; then
        log "INFO" "CSR auto-approver already deployed, skipping"
        return 0
    fi

    log "INFO" "Deploying CSR auto-approver for host cluster workers..."
    apply_manifest "$manifest" false
    log "INFO" "CSR auto-approver deployed successfully"
}

delete_csr_auto_approver() {
    # Remove CSR auto-approver CronJob from host cluster
    get_kubeconfig

    log "INFO" "Removing CSR auto-approver from host cluster..."
    oc delete cronjob -n openshift-machine-api csr-auto-approver --ignore-not-found
    oc delete clusterrolebinding csr-approver --ignore-not-found
    oc delete clusterrole csr-approver --ignore-not-found
    oc delete serviceaccount -n openshift-machine-api csr-approver --ignore-not-found
    log "INFO" "CSR auto-approver removed"
}


# Helper function to delete BMH with automated cleaning disabled
delete_bmh_with_cleanup() {
    local bmh_name="$1"

    if oc get bmh -n openshift-machine-api "$bmh_name" &>/dev/null; then
        log "INFO" "Disabling automated cleaning for BMH: $bmh_name (to skip IPA reboot)"
        oc patch bmh "$bmh_name" -n openshift-machine-api -p '{"spec":{"automatedCleaningMode":"disabled"}}' --type=merge || \
            log "WARN" "Failed to disable automated cleaning, continuing..."

        log "INFO" "Deleting BareMetalHost: $bmh_name"
        oc delete bmh -n openshift-machine-api "$bmh_name" --wait=false

        log "INFO" "Waiting for BMH deletion (this may take up to 15 minutes)..."
        if ! retry 60 15 bash -c "! oc get bmh -n openshift-machine-api '$bmh_name' &>/dev/null"; then
            log "ERROR" "Timed out waiting for BMH $bmh_name deletion"
            return 1
        fi

        log "INFO" "BMC secret will be automatically deleted (ownerReference to BMH)"
    else
        log "INFO" "BareMetalHost $bmh_name not found, skipping"
    fi
}

# Helper function to delete the OpenShift Node object
delete_node() {
    local node_name="$1"
    if [[ -z "$node_name" ]]; then
        log "WARN" "Node name not resolved, skipping node deletion"
        log "WARN" "You may need to manually delete the Node: oc get nodes && oc delete node <name>"
        return 0
    fi

    if oc get node "$node_name" &>/dev/null; then
        log "INFO" "Deleting Node: $node_name"
        oc delete node "$node_name"
        log "INFO" "Node $node_name deleted"
    else
        log "INFO" "Node $node_name not found, skipping"
    fi
}

delete_worker() {
    local input_name="${1:-}"
    [[ -z "$input_name" ]] && { log "ERROR" "Worker name required. Usage: $0 delete-worker <bmh-name|node-name>"; return 1; }

    get_kubeconfig

    log "INFO" "Identifying worker for: $input_name"

    local bmh_name=""
    local node_name=""

    # Check if it's a BMH name
    if oc get bmh -n openshift-machine-api "$input_name" &>/dev/null; then
        bmh_name="$input_name"
        log "INFO" "Identified as BareMetalHost: $bmh_name"

        # Get node name from BMH status.hardware.hostname
        node_name=$(oc get bmh -n openshift-machine-api "$bmh_name" -o jsonpath='{.status.hardware.hostname}' 2>/dev/null || true)

    # Check if it's a Node name — find BMH via matching hardware.hostname
    elif oc get node "$input_name" &>/dev/null; then
        node_name="$input_name"
        log "INFO" "Identified as Node: $node_name"

        # Find BMH with this hostname in status.hardware (BMH.status.hardware.hostname matches Node name)
        bmh_name=$(oc get bmh -n openshift-machine-api -o json 2>/dev/null | \
            jq -r --arg node "$node_name" \
            '.items[] | select(.status.hardware.hostname == $node) | .metadata.name' 2>/dev/null | head -1)

        if [[ -z "$bmh_name" ]]; then
            log "WARN" "Could not find BMH for node: $node_name (may already be deleted)"
        fi

    else
        log "ERROR" "Could not find BareMetalHost or Node named: $input_name"
        return 1
    fi

    [[ -z "$bmh_name" ]] && { log "ERROR" "Could not determine BareMetalHost name"; return 1; }

    log "INFO" "Worker mapping - BMH: $bmh_name, Node: ${node_name:-unknown}"

    # Delete BMH (handles all workers uniformly now — no MachineSet)
    log "INFO" "Deleting worker: $bmh_name"
    delete_bmh_with_cleanup "$bmh_name"

    # Delete the node if it exists
    delete_node "$node_name"

    log "INFO" "Worker $bmh_name deletion completed"
}

# Command dispatcher
case "${1:-}" in
    provision-all-workers) provision_all_workers ;;
    approve-worker-csrs) approve_worker_csrs ;;
    display-worker-status) display_worker_status ;;
    display-manual-csr-instructions) display_manual_csr_instructions ;;
    apply-short-worker-hostnames) apply_short_worker_hostnames ;;
    deploy-csr-auto-approver) deploy_csr_auto_approver ;;
    delete-csr-auto-approver) delete_csr_auto_approver ;;
    delete-worker) delete_worker "${2:-}" ;;
    *)
        echo "Usage: $0 {provision-all-workers|approve-worker-csrs|display-worker-status|display-manual-csr-instructions|apply-short-worker-hostnames|deploy-csr-auto-approver|delete-csr-auto-approver|delete-worker <bmh-name|machine-name|node-name>}"
        exit 1
        ;;
esac