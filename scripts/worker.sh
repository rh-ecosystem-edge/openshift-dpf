#!/bin/bash
# worker.sh - Worker node provisioning via BMO/IPMI

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/cluster.sh"

# Use existing path conventions from env.sh
WORKER_TEMPLATE_DIR="${MANIFESTS_DIR}/worker-provisioning"
WORKER_GENERATED_DIR="${GENERATED_DIR}/worker-provisioning"

# -----------------------------------------------------------------------------
# BMC power management (ipmitool) for script-based automation (clean-all/all)
# -----------------------------------------------------------------------------

# Helper to run ipmitool securely by passing password via a temporary file.
# Avoids passing credentials via command line arguments (-P) or environment variables (-E).
_run_ipmitool() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    shift 3
    # Remaining arguments are passed to ipmitool (e.g., power status)

    local pw_file
    pw_file=$(mktemp "${TMPDIR:-/tmp}/ipmipass.XXXXXX")
    printf "%s" "${pass}" > "${pw_file}"
    chmod 600 "${pw_file}"

    # Use a subshell to ensure we capture output and status correctly
    local status=0
    local output
    output=$(ipmitool -I lanplus -H "${bmc_ip}" -U "${user}" -f "${pw_file}" "$@" 2>/dev/null) || status=$?
    
    rm -f "${pw_file}"
    
    echo "${output}"
    return "${status}"
}

_bmc_get_power_state() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"

    local status_output
    status_output=$(_run_ipmitool "${bmc_ip}" "${user}" "${pass}" power status || echo "Unknown")
    
    if [[ "${status_output}" == *"is on"* ]]; then
        echo "On"
    elif [[ "${status_output}" == *"is off"* ]]; then
        echo "Off"
    else
        echo "Unknown"
    fi
}

_bmc_power_action() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local action="$4"

    log "INFO" "Attempting power '${action}' via ipmitool on ${bmc_ip}..."
    if ! _run_ipmitool "${bmc_ip}" "${user}" "${pass}" power "${action}" >/dev/null; then
        log "ERROR" "ipmitool power '${action}' failed on ${bmc_ip}"
        return 1
    fi
    return 0
}

# Poll power state until Off or the retry budget is exhausted.
_bmc_wait_for_off() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local max_retries="$4"
    local sleep_interval="$5"

    local retries=0 current_state
    while [[ $retries -lt $max_retries ]]; do
        sleep "${sleep_interval}"
        current_state=$(_bmc_get_power_state "${bmc_ip}" "${user}" "${pass}")
        if [[ "${current_state}" == "Off" ]]; then
            return 0
        fi
        retries=$((retries + 1))
    done
    return 1
}

# Poll power state until On or the retry budget is exhausted.
_bmc_wait_for_on() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local max_retries="$4"
    local sleep_interval="$5"

    local retries=0 current_state
    while [[ $retries -lt $max_retries ]]; do
        sleep "${sleep_interval}"
        current_state=$(_bmc_get_power_state "${bmc_ip}" "${user}" "${pass}")
        if [[ "${current_state}" == "On" ]]; then
            return 0
        fi
        retries=$((retries + 1))
    done
    return 1
}

# Power off a server: use graceful ACPI shutdown (soft) via IPMI
_bmc_power_off() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"

    local current_state
    current_state=$(_bmc_get_power_state "${bmc_ip}" "${user}" "${pass}")
    if [[ "${current_state}" == "Off" ]]; then
        log "INFO" "Server ${bmc_ip} is already off"
        return 0
    fi

    log "INFO" "Attempting graceful shutdown of ${bmc_ip} via ipmitool (soft)..."
    if _bmc_power_action "${bmc_ip}" "${user}" "${pass}" "soft"; then
        # Increase wait time for graceful shutdown to 60 retries * 2s = 120s (2 minutes)
        if _bmc_wait_for_off "${bmc_ip}" "${user}" "${pass}" 60 2; then
            log "INFO" "Server ${bmc_ip} shut down gracefully"
            return 0
        fi
        log "WARN" "Server ${bmc_ip} did not shut down gracefully within 120s"
    fi

    log "INFO" "Powering off ${bmc_ip} via ipmitool (off)..."
    _bmc_power_action "${bmc_ip}" "${user}" "${pass}" "off"

    if _bmc_wait_for_off "${bmc_ip}" "${user}" "${pass}" 30 2; then
        log "INFO" "Server ${bmc_ip} is powered off"
        return 0
    fi

    log "WARN" "Server ${bmc_ip} may not have fully powered off"
    return 1
}

# Power on a server via ipmitool. No-op if already On.
_bmc_power_on() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"

    local current_state
    current_state=$(_bmc_get_power_state "${bmc_ip}" "${user}" "${pass}")
    if [[ "${current_state}" == "On" ]]; then
        log "INFO" "Server ${bmc_ip} is already on"
        return 0
    fi

    log "INFO" "Powering on ${bmc_ip} via ipmitool..."
    _bmc_power_action "${bmc_ip}" "${user}" "${pass}" "on"

    if _bmc_wait_for_on "${bmc_ip}" "${user}" "${pass}" 30 2; then
        log "INFO" "Server ${bmc_ip} is powered on"
        return 0
    fi

    log "WARN" "Server ${bmc_ip} may not have fully powered on"
    return 1
}

_shutoff_worker() {
    local index="$1"

    local name_var="WORKER_${index}_NAME"
    local bmc_ip_var="WORKER_${index}_BMC_IP"
    local bmc_user_var="WORKER_${index}_BMC_USER"
    local bmc_pass_var="WORKER_${index}_BMC_PASSWORD"

    local name="${!name_var:-worker-${index}}"
    local bmc_ip="${!bmc_ip_var:-}"
    local bmc_user="${!bmc_user_var:-}"
    local bmc_pass="${!bmc_pass_var:-}"

    if [[ -z "${bmc_ip}" || -z "${bmc_user}" || -z "${bmc_pass}" ]]; then
        log "ERROR" "Worker ${index} (${name}) missing BMC credentials, cannot perform shutoff"
        return 1
    fi

    log "INFO" "Shutting off worker ${name} (${bmc_ip})..."
    _bmc_power_off "${bmc_ip}" "${bmc_user}" "${bmc_pass}"
}

shutoff_all_workers() {
    local count="${WORKER_COUNT:-0}"
    if [[ "${count}" -eq 0 ]]; then
        log "INFO" "WORKER_COUNT=0, skipping physical worker shutoff"
        return 0
    fi

    log "INFO" "Powering off ${count} physical worker(s) via ipmitool..."
    local failed=0
    for i in $(seq 1 "${count}"); do
        if ! _shutoff_worker "${i}"; then
            failed=$((failed + 1))
        fi
    done

    if [[ "${failed}" -gt 0 ]]; then
        log "WARN" "Failed to shut off ${failed}/${count} worker(s)"
        return 1
    fi

    log "INFO" "All configured workers powered off"
}

_poweron_worker() {
    local index="$1"

    local name_var="WORKER_${index}_NAME"
    local bmc_ip_var="WORKER_${index}_BMC_IP"
    local bmc_user_var="WORKER_${index}_BMC_USER"
    local bmc_pass_var="WORKER_${index}_BMC_PASSWORD"

    local name="${!name_var:-worker-${index}}"
    local bmc_ip="${!bmc_ip_var:-}"
    local bmc_user="${!bmc_user_var:-}"
    local bmc_pass="${!bmc_pass_var:-}"

    if [[ -z "${bmc_ip}" || -z "${bmc_user}" || -z "${bmc_pass}" ]]; then
        log "ERROR" "Worker ${index} (${name}) missing BMC credentials, cannot perform power-on"
        return 1
    fi

    log "INFO" "Powering on worker ${name} (${bmc_ip})..."
    _bmc_power_on "${bmc_ip}" "${bmc_user}" "${bmc_pass}"
}

# Power on all configured physical workers via ipmitool.
poweron_all_workers() {
    local count="${WORKER_COUNT:-0}"
    if [[ "${count}" -eq 0 ]]; then
        log "INFO" "WORKER_COUNT=0, skipping physical worker power-on"
        return 0
    fi

    log "INFO" "Powering on ${count} physical worker(s) via ipmitool..."
    local failed=0
    for i in $(seq 1 "${count}"); do
        if ! _poweron_worker "${i}"; then
            failed=$((failed + 1))
        fi
    done

    if [[ "${failed}" -gt 0 ]]; then
        log "WARN" "Failed to power on ${failed}/${count} worker(s)"
        return 1
    fi

    log "INFO" "All configured workers powered on"
}

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

    # Detect SNO environment (VM_COUNT=1)
    # In SNO with platform "None", Machine API is in NoOp mode and MachineSets won't work
    local is_sno=false
    [[ "${VM_COUNT:-0}" -eq 1 ]] && is_sno=true

    # Create shared MachineSet for DPU workers (only in non-SNO environments)
    if [[ "$is_sno" == "false" ]]; then
        # Create shared MachineSet if we have DPU workers and not SNO
        if [[ $dpu_count -gt 0 ]]; then
            log "INFO" "Creating/updating shared MachineSet for $dpu_count DPU worker(s)..."
            sed "s/replicas: 1/replicas: $dpu_count/" \
                "${WORKER_TEMPLATE_DIR}/machineset-dpu.yaml" \
                > "${WORKER_GENERATED_DIR}/machineset-dpu.yaml"
            retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/machineset-dpu.yaml" true

        fi
    else
        log "INFO" "SNO environment detected (VM_COUNT=1), skipping MachineSet creation (Machine API in NoOp mode)"
    fi

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

        # In SNO mode, always use basic baremetalhost.yaml (no MachineSet integration)
        # In non-SNO mode, use baremetalhost-dpu.yaml for DPU workers (with dpu-capable label)
        local filename="baremetalhost.yaml"
        if [[ "$is_sno" == "false" ]] && [[ "$is_dpu" == "true" ]]; then
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

# Command dispatcher
case "${1:-}" in
    provision-all-workers) provision_all_workers ;;
    approve-worker-csrs) approve_worker_csrs ;;
    display-worker-status) display_worker_status ;;
    display-manual-csr-instructions) display_manual_csr_instructions ;;
    apply-short-worker-hostnames) apply_short_worker_hostnames ;;
    deploy-csr-auto-approver) deploy_csr_auto_approver ;;
    delete-csr-auto-approver) delete_csr_auto_approver ;;
    shutoff-all-workers) shutoff_all_workers ;;
    poweron-all-workers) poweron_all_workers ;;
    *)
        echo "Usage: $0 {provision-all-workers|approve-worker-csrs|display-worker-status|display-manual-csr-instructions|apply-short-worker-hostnames|deploy-csr-auto-approver|delete-csr-auto-approver|delete-worker <bmh-name|machine-name|node-name>|shutoff-all-workers|poweron-all-workers}"
        exit 1
        ;;
esac
