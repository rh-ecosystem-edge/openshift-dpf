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

    # Apply custom node labels MachineConfig if configured
    apply_worker_node_labels

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

        if [[ "${WORKER_STATIC_IP}" == "true" ]]; then
           for var in WORKER_${i}_INT WORKER_${i}_IPADDR WORKER_${i}_GW WORKER_${i}_PL WORKER_${i}_DNS; do
              if [[ -z "${!var}" ]]; then
                 log "ERROR" "WORKER_STATIC_IP is enabled but $var is not set"
                 return 1
              fi
           done
           local ipaddr_var="WORKER_${i}_IPADDR"; local ipaddr="${!ipaddr_var}"
           local gw_var="WORKER_${i}_GW"; local gw="${!gw_var}"
           local int_var="WORKER_${i}_INT"; local int="${!int_var}"
           local pl_var="WORKER_${i}_PL"; local pl="${!pl_var}"
           local dns_var="WORKER_${i}_DNS"; local dns="${!dns_var}"

           #TBD dns array
           for ip in $ipaddr $gw $dns; do
             if ! is_valid_ip "$ip"; then
                log "ERROR" "ip not valid: $ip "
                return 1
             fi
           done
        fi

        log "INFO" "Creating manifests for $name..."

        # Generate BMC secret using process_template
        process_template \
           "${WORKER_TEMPLATE_DIR}/bmc-secret.yaml" \
           "${WORKER_GENERATED_DIR}/${name}-bmc-secret.yaml" \
           "<WORKER_NAME>" "$name" \
           "<BMC_USER_BASE64>" "$(printf '%s' "$bmc_user" | base64)" \
           "<BMC_PASSWORD_BASE64>" "$(printf '%s' "$bmc_pass" | base64)"

        if [[ "${WORKER_STATIC_IP}" == "true" ]]; then
           process_template \
               "${WORKER_TEMPLATE_DIR}/baremetalhost-static-ip.yaml" \
               "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" \
               "<WORKER_NAME>" "$name" \
               "<BOOT_MAC>" "$boot_mac" \
               "<BMC_IP>" "$bmc_ip" \
               "<ROOT_DEVICE>" "$root_dev"
           process_template \
               "${WORKER_TEMPLATE_DIR}/bmc-secret-static-ip.yaml" \
               "${WORKER_GENERATED_DIR}/${name}-bmc-secret-static-ip.yaml" \
               "<WORKER_NAME>" "$name" \
               "<BOOT_MAC>" "$boot_mac" \
               "<IPADDR>" "$ipaddr" \
               "<GW>" "$gw" \
               "<PL>" "$pl" \
               "<INTERFACE>" "$int" \
               "<NODES_MTU>" "${NODES_MTU}" \
               "<DNS_IP>" "$dns"
        else
           # Generate BareMetalHost using process_template
           process_template \
              "${WORKER_TEMPLATE_DIR}/baremetalhost.yaml" \
              "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" \
              "<WORKER_NAME>" "$name" \
              "<BOOT_MAC>" "$boot_mac" \
              "<BMC_IP>" "$bmc_ip" \
              "<ROOT_DEVICE>" "$root_dev"
        fi

        # Apply manifests
        if [[ "${WORKER_STATIC_IP}" == "true" ]]; then
            retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmc-secret-static-ip.yaml" false
        fi
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

apply_worker_node_labels() {
    if [[ -z "${WORKER_NODE_LABELS:-}" ]]; then
        log "INFO" "WORKER_NODE_LABELS not set, skipping custom node labels MachineConfig"
        return 0
    fi

    get_kubeconfig

    local template="${WORKER_TEMPLATE_DIR}/99-worker-node-labels.yaml"
    if [[ ! -f "$template" ]]; then
        log "ERROR" "Worker node labels manifest template not found: $template"
        return 1
    fi

    mkdir -p "${WORKER_GENERATED_DIR}"

    local kubelet_env_base64
    kubelet_env_base64=$(printf 'CUSTOM_KUBELET_LABELS=%s\n' "$WORKER_NODE_LABELS" | base64 | tr -d '\n')

    local output="${WORKER_GENERATED_DIR}/99-worker-node-labels.yaml"
    process_template \
        "$template" \
        "$output" \
        "<KUBELET_ENV_BASE64>" "$kubelet_env_base64"

    log "INFO" "Applying worker node labels MachineConfig (labels: $WORKER_NODE_LABELS)..."
    apply_manifest "$output" false
    log "INFO" "Worker node labels MachineConfig applied successfully"
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

# Command dispatcher
case "${1:-}" in
    provision-all-workers) provision_all_workers ;;
    approve-worker-csrs) approve_worker_csrs ;;
    display-worker-status) display_worker_status ;;
    display-manual-csr-instructions) display_manual_csr_instructions ;;
    apply-short-worker-hostnames) apply_short_worker_hostnames ;;
    deploy-csr-auto-approver) deploy_csr_auto_approver ;;
    delete-csr-auto-approver) delete_csr_auto_approver ;;
    *)
        echo "Usage: $0 {provision-all-workers|approve-worker-csrs|display-worker-status|display-manual-csr-instructions|apply-short-worker-hostnames|deploy-csr-auto-approver|delete-csr-auto-approver}"
        exit 1
        ;;
esac
