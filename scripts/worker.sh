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

        # In non-SNO mode, DPU workers use baremetalhost-dpu.yaml (MachineSet provides userData)
        # In SNO mode (or non-DPU workers), use baremetalhost.yaml with direct userData reference
        local filename="baremetalhost.yaml"
        if [[ "$is_sno" == "false" ]] && [[ "$is_dpu" == "true" ]]; then
            filename="baremetalhost-dpu.yaml"
        fi

        # Determine userData secret: DPU workers boot into worker-dpu pool
        local user_data_secret="worker-user-data-managed"
        if [[ "$is_dpu" == "true" ]]; then
            user_data_secret="worker-dpu-user-data-managed"
        fi

        # Generate BareMetalHost using appropriate template
        process_template \
            "${WORKER_TEMPLATE_DIR}/$filename" \
            "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" \
            "<WORKER_NAME>" "$name" \
            "<BOOT_MAC>" "$boot_mac" \
            "<BMC_IP>" "$bmc_ip" \
            "<ROOT_DEVICE>" "$root_dev" \
            "<USER_DATA_SECRET>" "$user_data_secret"
	
        # Apply manifests (retry for transient API/controller or network failures)
        retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmc-secret.yaml" false
        retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" false

        log "INFO" "BMH $name created"
    done

    log "INFO" "Worker provisioning initiated"
}

# -----------------------------------------------------------------------------
# Assisted Installer Day-2 provisioning for physical workers
# -----------------------------------------------------------------------------
# This flow boots workers from the Day-2 discovery ISO (via Redfish virtual media),
# waits for them to register with the Assisted Installer service, sets
# mcp=worker-dpu so they boot directly into the worker-dpu MachineConfigPool,
# then triggers installation.
#
# Pre-requisites:
#   - Cluster must be in day2 mode (run: make create-day2-cluster)
#   - Day-2 discovery ISO must be available (run: make download-day2-iso)
#   - WORKER_COUNT and WORKER_N_* variables must be set
# -----------------------------------------------------------------------------

provision_workers_assisted() {
    local target="${1:-}"
    local count="${WORKER_COUNT:-0}"
    [[ "$count" -eq 0 ]] && { log "INFO" "WORKER_COUNT=0, skipping"; return 0; }

    log "INFO" "Provisioning worker(s) via Assisted Installer Day-2 flow..."

    # Ensure cluster is in day2 mode
    source "${SCRIPT_DIR}/cluster.sh"
    create_day2_cluster

    # Get day2 cluster and infraenv IDs
    local cluster_id infra_env_id
    cluster_id=$(get_day2_cluster_id) || return 1
    infra_env_id=$(get_day2_infra_env_id "${ARCH}") || return 1

    # Boot workers from Day-2 ISO via Redfish virtual media
    local iso_url
    if [[ -n "${WORKER_ISO_URL:-}" ]]; then
        iso_url="${WORKER_ISO_URL}"
        log "INFO" "Using override ISO URL (WORKER_ISO_URL): ${iso_url}"
    else
        # get_iso logs to stdout (log "INFO" goes to stdout in this codebase),
        # so grab only the last line which is the actual URL
        iso_url=$(get_iso "${CLUSTER_NAME}" "day2" "url" | tail -1) || return 1
        # Strip any ANSI color codes that might leak through
        iso_url=$(echo "$iso_url" | sed 's/\x1b\[[0-9;]*m//g')
        log "INFO" "Day-2 ISO URL: ${iso_url}"
    fi

    # Build list of worker indices to provision
    local indices=()
    if [[ -n "$target" ]]; then
        # Target can be an index (e.g. "1") or a name (e.g. "perf-worker-27")
        if [[ "$target" =~ ^[0-9]+$ ]]; then
            indices=("$target")
        else
            # Find index by name
            for i in $(seq 1 "$count"); do
                local name_var="WORKER_${i}_NAME"
                if [[ "${!name_var}" == "$target" ]]; then
                    indices=("$i")
                    break
                fi
            done
            [[ ${#indices[@]} -eq 0 ]] && { log "ERROR" "Worker '$target' not found in WORKER_1..${count}_NAME"; return 1; }
        fi
    else
        for i in $(seq 1 "$count"); do indices+=("$i"); done
    fi

    local expected_count=${#indices[@]}
    log "INFO" "Provisioning ${expected_count} worker(s): ${indices[*]}"

    # Check which hosts are already registered/installed and decide what to do
    local hosts_to_boot=()
    local hosts_already_known=0
    local hosts_already_installed=0

    for i in "${indices[@]}"; do
        local name_var="WORKER_${i}_NAME"; local name="${!name_var}"
        [[ -z "$name" ]] && { log "ERROR" "WORKER_${i}_NAME not set"; return 1; }

        # Check if host is already in assisted installer by hostname
        local host_status
        host_status=$(aicli -o json list hosts 2>/dev/null \
            | jq -r --arg ieid "${infra_env_id}" --arg hostname "${name}" \
              '.[] | select(.infra_env_id == $ieid and .requested_hostname == $hostname) | .status' \
            | head -1) || host_status=""

        # Also check by matching on the inventory hostname (for auto-discovered hosts)
        if [[ -z "$host_status" ]]; then
            host_status=$(aicli -o json list hosts 2>/dev/null \
                | jq -r --arg ieid "${infra_env_id}" --arg hostname "${name}" \
                  '.[] | select(.infra_env_id == $ieid and (.inventory // "" | contains($hostname))) | .status' \
                | head -1) || host_status=""
        fi

        case "$host_status" in
            installed|added-to-existing-cluster)
                log "INFO" "Host ${name} already installed (status: ${host_status}), skipping"
                ((hosts_already_installed++)) || true
                ;;
            known|insufficient|pending-for-input)
                log "INFO" "Host ${name} already registered (status: ${host_status}), skipping boot"
                ((hosts_already_known++)) || true
                ;;
            *)
                log "INFO" "Host ${name} not found or status='${host_status}', will boot from ISO"
                hosts_to_boot+=("$i")
                ;;
        esac
    done

    # Subtract already-installed hosts from expected count
    expected_count=$((expected_count - hosts_already_installed))
    if [[ "$expected_count" -le 0 ]]; then
        log "INFO" "All targeted hosts are already installed, nothing to do"
        return 0
    fi

    # Boot only the hosts that need it
    if [[ ${#hosts_to_boot[@]} -gt 0 ]]; then
        if [[ "${SKIP_REDFISH_BOOT:-false}" == "true" ]]; then
            log "INFO" "SKIP_REDFISH_BOOT=true — skipping Redfish virtual media boot (assuming manual boot)"
        else
            for i in "${hosts_to_boot[@]}"; do
                local name_var="WORKER_${i}_NAME"; local name="${!name_var}"
                local bmc_ip_var="WORKER_${i}_BMC_IP"; local bmc_ip="${!bmc_ip_var}"
                local bmc_user_var="WORKER_${i}_BMC_USER"; local bmc_user="${!bmc_user_var}"
                local bmc_pass_var="WORKER_${i}_BMC_PASSWORD"; local bmc_pass="${!bmc_pass_var}"
                local redfish_path_var="WORKER_${i}_REDFISH_SYSTEM_PATH"; local redfish_path="${!redfish_path_var:-}"

                [[ -z "$bmc_ip" ]] && { log "ERROR" "WORKER_${i}_BMC_IP not set"; return 1; }
                [[ -z "$bmc_user" ]] && { log "ERROR" "WORKER_${i}_BMC_USER not set"; return 1; }
                [[ -z "$bmc_pass" ]] && { log "ERROR" "WORKER_${i}_BMC_PASSWORD not set"; return 1; }

                log "INFO" "Booting $name from Day-2 ISO via Redfish virtual media..."
                boot_from_iso_via_redfish "$bmc_ip" "$bmc_user" "$bmc_pass" "$iso_url" "$redfish_path"
            done
        fi
    else
        log "INFO" "All hosts already registered, skipping boot phase"
    fi

    # Find the exact host IDs for our target workers
    log "INFO" "Looking up host IDs for target worker(s)..."
    local target_host_ids=()
    local all_hosts_json
    all_hosts_json=$(aicli -o json list hosts 2>/dev/null) || all_hosts_json="[]"

    _find_host_id_by_name() {
        local hostname="$1"
        echo "$all_hosts_json" \
            | jq -r --arg ieid "${infra_env_id}" --arg hostname "${hostname}" \
              '.[] | select(.infra_env_id == $ieid and ((.requested_hostname // "") == $hostname or (.inventory // "" | contains($hostname)))) | .id' \
            | head -1
    }

    # Wait for target hosts to register (status == "known")
    log "INFO" "Waiting for ${expected_count} host(s) to register with Assisted Installer..."
    _check_hosts_registered() {
        all_hosts_json=$(aicli -o json list hosts 2>/dev/null) || all_hosts_json="[]"
        local registered=0
        for i in "${indices[@]}"; do
            local name_var="WORKER_${i}_NAME"; local name="${!name_var}"
            local status
            status=$(echo "$all_hosts_json" \
                | jq -r --arg ieid "${infra_env_id}" --arg hostname "${name}" \
                  '.[] | select(.infra_env_id == $ieid and ((.requested_hostname // "") == $hostname or (.inventory // "" | contains($hostname)))) | .status' \
                | head -1) || status=""
            case "$status" in
                known|installed|added-to-existing-cluster|installing|installing-in-progress)
                    ((registered++)) || true ;;
            esac
        done
        log "INFO" "Hosts registered: ${registered}/${expected_count}"
        [ "${registered}" -ge "${expected_count}" ]
    }
    if ! retry 60 30 _check_hosts_registered; then
        log "ERROR" "Timeout waiting for hosts to register"
        return 1
    fi

    # Collect host IDs for our specific targets
    all_hosts_json=$(aicli -o json list hosts 2>/dev/null) || all_hosts_json="[]"
    for i in "${indices[@]}"; do
        local name_var="WORKER_${i}_NAME"; local name="${!name_var}"
        local host_id
        host_id=$(_find_host_id_by_name "$name")
        if [[ -n "$host_id" ]]; then
            target_host_ids+=("$host_id")
            log "INFO" "Host ${name} → ID ${host_id}"
        else
            log "WARN" "Could not find host ID for ${name} in infra-env"
        fi
    done

    # Bind hosts, set MCP, and start installation
    local day2_mcp="worker-dpu"
    log "INFO" "Setting mcp=${day2_mcp} on ${#target_host_ids[@]} host(s) and starting installation..."

    _bind_and_install() {
        all_hosts_json=$(aicli -o json list hosts 2>/dev/null) || all_hosts_json="[]"
        for host_id in "${target_host_ids[@]}"; do
            local status
            status=$(echo "$all_hosts_json" | jq -r --arg hid "$host_id" '.[] | select(.id == $hid) | .status') || status=""
            case "$status" in
                known)
                    log "INFO" "Binding host ${host_id}..."
                    aicli bind host "${host_id}" --cluster "${CLUSTER_NAME}" || true
                    sleep 2
                    log "INFO" "Setting mcp=${day2_mcp} on host ${host_id}..."
                    aicli update host "${host_id}" -P mcp="${day2_mcp}" || true
                    log "INFO" "Starting installation for host ${host_id}..."
                    aicli start host "${host_id}" || true
                    ;;
                installed|added-to-existing-cluster)
                    log "INFO" "Host ${host_id} already installed, skipping"
                    ;;
                installing|installing-in-progress)
                    log "INFO" "Host ${host_id} already installing, skipping"
                    ;;
            esac
        done
    }

    _bind_and_install

    # Wait for installation to complete — check exact host IDs
    log "INFO" "Waiting for ${expected_count} host(s) to complete installation..."
    _check_hosts_installed() {
        _bind_and_install
        all_hosts_json=$(aicli -o json list hosts 2>/dev/null) || all_hosts_json="[]"
        local installed_count=0
        for host_id in "${target_host_ids[@]}"; do
            local status
            status=$(echo "$all_hosts_json" | jq -r --arg hid "$host_id" '.[] | select(.id == $hid) | .status') || status=""
            case "$status" in
                installed|added-to-existing-cluster) ((installed_count++)) || true ;;
            esac
        done
        log "INFO" "Hosts installed: ${installed_count}/${expected_count}"
        [ "${installed_count}" -ge "${expected_count}" ]
    }
    if ! retry 120 60 _check_hosts_installed; then
        log "ERROR" "Timeout waiting for hosts to complete installation"
        return 1
    fi

    log "INFO" "All ${expected_count} worker(s) installed via Assisted Installer"
}

# Boot a host from ISO via Redfish virtual media
# Supports Dell iDRAC and generic Redfish BMCs.
# Args: bmc_ip bmc_user bmc_pass iso_url [redfish_system_path]
boot_from_iso_via_redfish() {
    local bmc_ip="$1" bmc_user="$2" bmc_pass="$3" iso_url="$4"
    local system_path="${5:-}"
    local bmc_base="https://${bmc_ip}"

    # Dell iDRAC paths (default); override system_path if provided
    local manager_path="Managers/iDRAC.Embedded.1"
    local vm_resource="VirtualMedia/CD"
    if [[ -z "$system_path" ]]; then
        system_path="Systems/System.Embedded.1"
    fi

    local system_endpoint="${bmc_base}/redfish/v1/${system_path}"
    local reset_endpoint="${system_endpoint}/Actions/ComputerSystem.Reset"
    local vm_endpoint="${bmc_base}/redfish/v1/${manager_path}/${vm_resource}"

    # --- Step 1: Force power off (ensures clean boot from virtual media) ---
    log "INFO" "[${bmc_ip}] Powering off host..."
    local http_code
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "${reset_endpoint}" \
        -u "${bmc_user}:${bmc_pass}" \
        -H "Content-Type: application/json" \
        -d '{"ResetType": "ForceOff"}') || true
    if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
        log "INFO" "[${bmc_ip}] ForceOff accepted, waiting 10s for host to power down..."
        sleep 10
    else
        log "INFO" "[${bmc_ip}] ForceOff returned HTTP ${http_code} (host may already be off)"
    fi

    # --- Step 2: Eject any existing virtual media ---
    log "INFO" "[${bmc_ip}] Ejecting existing virtual media..."
    curl -sk -X POST "${vm_endpoint}/Actions/VirtualMedia.EjectMedia" \
        -u "${bmc_user}:${bmc_pass}" \
        -H "Content-Type: application/json" \
        -d '{}' 2>/dev/null || true
    sleep 2

    # --- Step 3: Insert ISO via virtual media ---
    log "INFO" "[${bmc_ip}] Inserting virtual media ISO..."
    local insert_response
    insert_response=$(curl -sk -w '\n%{http_code}' -X POST \
        "${vm_endpoint}/Actions/VirtualMedia.InsertMedia" \
        -u "${bmc_user}:${bmc_pass}" \
        -H "Content-Type: application/json" \
        -d "{\"Image\": \"${iso_url}\", \"Inserted\": true, \"WriteProtected\": true}") || true

    http_code=$(echo "$insert_response" | tail -1)
    local insert_body
    insert_body=$(echo "$insert_response" | sed '$d')

    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        log "ERROR" "[${bmc_ip}] Insert virtual media failed (HTTP ${http_code}): ${insert_body}"
        return 1
    fi
    log "INFO" "[${bmc_ip}] Insert returned HTTP ${http_code}"

    # --- Step 4: Verify ISO is actually mounted ---
    sleep 3
    log "INFO" "[${bmc_ip}] Verifying virtual media status..."
    local vm_status
    vm_status=$(curl -sk -u "${bmc_user}:${bmc_pass}" "${vm_endpoint}" | jq -r '.Inserted // "null"') || vm_status="unknown"
    if [[ "$vm_status" != "true" ]]; then
        log "ERROR" "[${bmc_ip}] Virtual media NOT mounted (Inserted=${vm_status}). The BMC may not be able to reach the ISO URL."
        log "ERROR" "[${bmc_ip}] ISO URL: ${iso_url}"
        log "ERROR" "[${bmc_ip}] Consider downloading the ISO and serving it via a local HTTP server reachable by the BMC."
        return 1
    fi
    log "INFO" "[${bmc_ip}] Virtual media verified: Inserted=true"

    # --- Step 5: Set one-time boot override to virtual CD (UEFI) ---
    log "INFO" "[${bmc_ip}] Setting boot override to Cd (UEFI, once)..."
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' -X PATCH "${system_endpoint}" \
        -u "${bmc_user}:${bmc_pass}" \
        -H "Content-Type: application/json" \
        -d '{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideMode": "UEFI", "BootSourceOverrideEnabled": "Once"}}') || true
    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        log "WARN" "[${bmc_ip}] Boot override returned HTTP ${http_code} (may still work)"
    fi

    # --- Step 6: Power on ---
    log "INFO" "[${bmc_ip}] Powering on host..."
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "${reset_endpoint}" \
        -u "${bmc_user}:${bmc_pass}" \
        -H "Content-Type: application/json" \
        -d '{"ResetType": "On"}') || true
    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
        log "ERROR" "[${bmc_ip}] PowerOn failed (HTTP ${http_code})"
        return 1
    fi

    log "INFO" "[${bmc_ip}] Boot from virtual media initiated successfully"
}

# Dispatcher: choose provisioning method based on WORKER_PROVISIONING_METHOD
provision_workers() {
    local method="${WORKER_PROVISIONING_METHOD:-bmh}"
    case "$method" in
        bmh)
            log "INFO" "Using BMH/Redfish provisioning method"
            provision_all_workers
            ;;
        assisted)
            log "INFO" "Using Assisted Installer Day-2 provisioning method"
            provision_workers_assisted
            ;;
        *)
            log "ERROR" "Unknown WORKER_PROVISIONING_METHOD: $method (valid: bmh, assisted)"
            return 1
            ;;
    esac
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

# Helper function to decrease MachineSet replica count
decrease_machineset_replicas() {
    log "INFO" "Updating MachineSet replica count to prevent recreation..."
    local current_replicas
    current_replicas=$(oc get machinesets.machine.openshift.io worker-dpu -n openshift-machine-api -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    if [[ "$current_replicas" -gt 0 ]]; then
        local new_replicas=$((current_replicas - 1))
        log "INFO" "Decreasing MachineSet replicas: $current_replicas → $new_replicas"
        oc patch machinesets.machine.openshift.io worker-dpu -n openshift-machine-api --type=merge -p "{\"spec\":{\"replicas\":$new_replicas}}"
    else
        log "WARN" "MachineSet worker-dpu has 0 replicas or not found"
    fi
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

# Helper function to warn about manual node deletion
warn_manual_node_deletion() {
    log "WARN" "*** IMPORTANT: You must manually delete the OpenShift Node object ***"
    log "WARN" "*** Run: oc get nodes (find the node) then: oc delete node <node-name> ***"
}

delete_worker() {
    local input_name="${1:-}"
    [[ -z "$input_name" ]] && { log "ERROR" "Worker name required. Usage: $0 delete-worker <bmh-name|machine-name>"; return 1; }

    get_kubeconfig

    log "INFO" "Identifying worker type for: $input_name"

    # Try to identify what type of name was provided and find the BMH name
    local bmh_name=""
    local machine_name=""

    # Check if it's a BMH name
    if oc get bmh -n openshift-machine-api "$input_name" &>/dev/null; then
        bmh_name="$input_name"
        log "INFO" "Identified as BareMetalHost: $bmh_name"

        # Get Machine consuming this BMH
        machine_name=$(oc get machines.machine.openshift.io -n openshift-machine-api -o json 2>/dev/null | \
            jq -r --arg bmh "$bmh_name" \
            '.items[] | select((.metadata.annotations."metal3.io/BareMetalHost" // "" | split("/") | last) == $bmh) | .metadata.name' 2>/dev/null | head -1)

    # Check if it's a Machine name
    elif oc get machines.machine.openshift.io -n openshift-machine-api "$input_name" &>/dev/null; then
        machine_name="$input_name"
        log "INFO" "Identified as Machine: $machine_name"

        # Get BMH from Machine annotation
        bmh_name=$(oc get machines.machine.openshift.io -n openshift-machine-api "$machine_name" -o json 2>/dev/null | \
            jq -r '.metadata.annotations."metal3.io/BareMetalHost" // ""' | sed 's|.*/||' 2>/dev/null || true)

    else
        log "ERROR" "Could not find BareMetalHost or Machine named: $input_name"
        return 1
    fi

    log "INFO" "Worker mapping - BMH: ${bmh_name:-none}, Machine: ${machine_name:-none}"

    [[ -z "$bmh_name" ]] && { log "ERROR" "Could not determine BareMetalHost name"; return 1; }

    # Find worker index and check if it's a DPU worker
    local worker_index=""
    local is_dpu="false"
    for i in $(seq 1 "${WORKER_COUNT:-0}"); do
        local name_var="WORKER_${i}_NAME"
        if [[ "${!name_var}" == "$bmh_name" ]]; then
            worker_index=$i
            local dpu_var="WORKER_${i}_DPU"
            is_dpu="${!dpu_var:-true}"
            break
        fi
    done

    if [[ -z "$worker_index" ]]; then
        log "WARN" "Worker $bmh_name not found in environment variables"
        # Try to detect if it's DPU by checking if Machine has the dpu-capable selector
        if [[ -n "$machine_name" ]]; then
            local has_dpu_label
            has_dpu_label=$(oc get machines.machine.openshift.io -n openshift-machine-api "$machine_name" -o json 2>/dev/null | \
                jq -r '.spec.providerSpec.value.hostSelector.matchLabels."dpu-capable" // "false"')
            [[ "$has_dpu_label" == "true" ]] && is_dpu="true"
        fi
    fi

    log "INFO" "Deleting worker: $bmh_name (DPU: $is_dpu)"

    # Handle DPU workers (managed by MachineSet)
    if [[ "$is_dpu" == "true" ]]; then
        log "INFO" "DPU worker detected, managing Machine and MachineSet..."

        # STEP 1: Disable automated cleaning on BMH FIRST (before triggering any deprovisioning)
        if oc get bmh -n openshift-machine-api "$bmh_name" &>/dev/null; then
            log "INFO" "Disabling automated cleaning for BMH: $bmh_name (to skip IPA reboot)"
            oc patch bmh "$bmh_name" -n openshift-machine-api -p '{"spec":{"automatedCleaningMode":"disabled"}}' --type=merge || \
                log "WARN" "Failed to disable automated cleaning, continuing..."
        fi

        # STEP 2 & 3: Delete specific Machine and immediately decrease replicas (minimize race window)
        if [[ -n "$machine_name" ]]; then
            log "INFO" "Deleting Machine: $machine_name and decreasing MachineSet replicas"
            oc delete machines.machine.openshift.io -n openshift-machine-api "$machine_name" --wait=false

            # Immediately decrease replica count to prevent MachineSet from recreating
            decrease_machineset_replicas

            log "INFO" "Waiting for Machine deletion (this may take up to 15 minutes)..."
            if ! retry 60 15 bash -c "! oc get machines.machine.openshift.io -n openshift-machine-api '$machine_name' &>/dev/null"; then
                log "ERROR" "Timed out waiting for Machine $machine_name deletion"
                return 1
            fi
        else
            log "WARN" "No Machine found associated with BMH $bmh_name"
            # Still decrease replica count even if Machine not found
            decrease_machineset_replicas
        fi

        # STEP 4: Delete BMH if it still exists (cleaning already disabled in step 1)
        if oc get bmh -n openshift-machine-api "$bmh_name" &>/dev/null; then
            log "INFO" "Deleting BareMetalHost: $bmh_name"
            oc delete bmh -n openshift-machine-api "$bmh_name" --wait=false

            log "INFO" "Waiting for BMH deletion (this may take up to 15 minutes)..."
            if ! retry 60 15 bash -c "! oc get bmh -n openshift-machine-api '$bmh_name' &>/dev/null"; then
                log "ERROR" "Timed out waiting for BMH $bmh_name deletion"
                return 1
            fi

            log "INFO" "BMC secret will be automatically deleted (ownerReference to BMH)"
        else
            log "INFO" "BareMetalHost $bmh_name already deleted (consumed by Machine)"
        fi

        warn_manual_node_deletion

    # Handle regular (non-DPU) workers
    else
        log "INFO" "Regular worker detected (no MachineSet management)"
        delete_bmh_with_cleanup "$bmh_name"
        warn_manual_node_deletion
    fi

    log "INFO" "Worker $bmh_name deletion completed"
}

# Command dispatcher
case "${1:-}" in
    provision-all-workers) provision_all_workers ;;
    provision-workers-assisted) provision_workers_assisted "${2:-}" ;;
    provision-workers) provision_workers ;;
    approve-worker-csrs) approve_worker_csrs ;;
    display-worker-status) display_worker_status ;;
    display-manual-csr-instructions) display_manual_csr_instructions ;;
    apply-short-worker-hostnames) apply_short_worker_hostnames ;;
    deploy-csr-auto-approver) deploy_csr_auto_approver ;;
    delete-csr-auto-approver) delete_csr_auto_approver ;;
    delete-worker) delete_worker "${2:-}" ;;
    *)
        echo "Usage: $0 {provision-workers|provision-all-workers|provision-workers-assisted|approve-worker-csrs|display-worker-status|display-manual-csr-instructions|apply-short-worker-hostnames|deploy-csr-auto-approver|delete-csr-auto-approver|delete-worker <name>}"
        exit 1
        ;;
esac
