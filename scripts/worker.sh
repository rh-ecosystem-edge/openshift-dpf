#!/bin/bash
# worker.sh - Worker node provisioning via BMO/Redfish or direct Redfish
#
# Supports two provisioning methods controlled by WORKER_PROVISION_METHOD:
#   bmo     - (default) Creates BareMetalHost CRDs, provisioned via BMO/Ironic
#   redfish - Direct Redfish API calls: mount ISO, boot from CD, install via AI day2

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/cluster.sh"

# Use existing path conventions from env.sh
WORKER_TEMPLATE_DIR="${MANIFESTS_DIR}/worker-provisioning"
WORKER_GENERATED_DIR="${GENERATED_DIR}/worker-provisioning"

# Source redfish functions when using direct Redfish provisioning
if [ "${WORKER_PROVISION_METHOD:-bmo}" = "redfish" ]; then
    source "${SCRIPT_DIR}/redfish.sh" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Common: extract per-worker config variables
# ---------------------------------------------------------------------------
_get_worker_config() {
    local i="$1"

    WORKER_NAME_VAR="WORKER_${i}_NAME"; WORKER_NAME="${!WORKER_NAME_VAR}"
    WORKER_BMC_IP_VAR="WORKER_${i}_BMC_IP"; WORKER_BMC_IP="${!WORKER_BMC_IP_VAR}"
    WORKER_BMC_USER_VAR="WORKER_${i}_BMC_USER"; WORKER_BMC_USER="${!WORKER_BMC_USER_VAR}"
    WORKER_BMC_PASS_VAR="WORKER_${i}_BMC_PASSWORD"; WORKER_BMC_PASS="${!WORKER_BMC_PASS_VAR}"
    WORKER_BOOT_MAC_VAR="WORKER_${i}_BOOT_MAC"; WORKER_BOOT_MAC="${!WORKER_BOOT_MAC_VAR}"
    WORKER_ROOT_DEV_VAR="WORKER_${i}_ROOT_DEVICE"; WORKER_ROOT_DEV="${!WORKER_ROOT_DEV_VAR:-/dev/sda}"

    [[ -z "$WORKER_NAME" ]] && { log "ERROR" "${WORKER_NAME_VAR} not set"; return 1; }
    [[ -z "$WORKER_BMC_IP" ]] && { log "ERROR" "${WORKER_BMC_IP_VAR} not set"; return 1; }
    [[ -z "$WORKER_BMC_USER" ]] && { log "ERROR" "${WORKER_BMC_USER_VAR} not set"; return 1; }
    [[ -z "$WORKER_BMC_PASS" ]] && { log "ERROR" "${WORKER_BMC_PASS_VAR} not set"; return 1; }
    # Boot MAC is only required for BMO path (DHCP/PXE identification)
    # Redfish path mounts ISO via VirtualMedia — no MAC needed
    if [ "${WORKER_PROVISION_METHOD:-bmo}" = "bmo" ]; then
        [[ -z "$WORKER_BOOT_MAC" ]] && { log "ERROR" "${WORKER_BOOT_MAC_VAR} not set"; return 1; }
    fi
}

# ---------------------------------------------------------------------------
# Download ISO to an HTTP-accessible location for BMC VirtualMedia.
# Uses REDFISH_ISO_BASEURL / REDFISH_ISO_HOSTPATH / REDFISH_ISO_HOST from env.
# Returns the rewritten URL on stdout.
# ---------------------------------------------------------------------------
_download_iso_to_http() {
    local iso_url="$1"
    local iso_filename="$2"

    if [[ -z "${REDFISH_ISO_BASEURL:-}" || -z "${REDFISH_ISO_HOSTPATH:-}" ]]; then
        log "ERROR" "REDFISH_ISO_BASEURL and REDFISH_ISO_HOSTPATH must be set for Redfish provisioning" >&2
        log "ERROR" "See docs/user-guide/redfish-worker-provisioning.md for setup instructions" >&2
        return 1
    fi

    log "INFO" "Downloading ISO to HTTP server for BMC access..." >&2
    if [[ -n "${REDFISH_ISO_HOST:-}" ]]; then
        # Remote mode — download via SSH
        ssh -o StrictHostKeyChecking=no "${REDFISH_ISO_HOST}" "mkdir -p '${REDFISH_ISO_HOSTPATH}'" || return 1
        # Always re-download — stale ISOs from previous clusters cause boot failures
        ssh -o StrictHostKeyChecking=no "${REDFISH_ISO_HOST}" \
            "wget -q -O '${REDFISH_ISO_HOSTPATH}/${iso_filename}' '${iso_url}'" || {
            log "ERROR" "Failed to download ISO on ${REDFISH_ISO_HOST}" >&2
            return 1
        }
    else
        # Local mode — download directly
        mkdir -p "${REDFISH_ISO_HOSTPATH}" || return 1
        # Always re-download — stale ISOs from previous clusters cause boot failures
        wget -q -O "${REDFISH_ISO_HOSTPATH}/${iso_filename}" "${iso_url}" || {
                log "ERROR" "Failed to download ISO locally" >&2
                return 1
            }
    fi
    echo "${REDFISH_ISO_BASEURL}/${iso_filename}"
}

# ---------------------------------------------------------------------------
# BMO provisioning path (original)
# ---------------------------------------------------------------------------
_provision_workers_bmo() {
    local count="$1"

    # BMO is pre-installed in OpenShift - verify it's available
    if ! oc get clusteroperator baremetal &>/dev/null; then
        log "ERROR" "Baremetal cluster operator not found. This should not happen in OpenShift."
        return 1
    fi

    # Ensure Provisioning CR exists (apply_manifest handles existence check)
    apply_manifest "${WORKER_TEMPLATE_DIR}/provisioning.yaml" false

    mkdir -p "${WORKER_GENERATED_DIR}"
    log "INFO" "Provisioning ${count} worker(s) via BMO..."

    for i in $(seq 1 "$count"); do
        _get_worker_config "$i" || return 1

        # Skip if already exists (idempotent)
        if oc get bmh -n openshift-machine-api "$WORKER_NAME" &>/dev/null; then
            log "INFO" "BMH $WORKER_NAME already exists, skipping"
            continue
        fi

        log "INFO" "Creating manifests for $WORKER_NAME..."

        # Generate BMC secret using process_template
        process_template \
            "${WORKER_TEMPLATE_DIR}/bmc-secret.yaml" \
            "${WORKER_GENERATED_DIR}/${WORKER_NAME}-bmc-secret.yaml" \
            "<WORKER_NAME>" "$WORKER_NAME" \
            "<BMC_USER_BASE64>" "$(printf '%s' "$WORKER_BMC_USER" | base64)" \
            "<BMC_PASSWORD_BASE64>" "$(printf '%s' "$WORKER_BMC_PASS" | base64)"

        # Generate BareMetalHost using process_template
        process_template \
            "${WORKER_TEMPLATE_DIR}/baremetalhost.yaml" \
            "${WORKER_GENERATED_DIR}/${WORKER_NAME}-bmh.yaml" \
            "<WORKER_NAME>" "$WORKER_NAME" \
            "<BOOT_MAC>" "$WORKER_BOOT_MAC" \
            "<BMC_IP>" "$WORKER_BMC_IP" \
            "<ROOT_DEVICE>" "$WORKER_ROOT_DEV"

        # Apply manifests (retry for transient API/controller or network failures)
        retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/${WORKER_NAME}-bmc-secret.yaml" false
        retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/${WORKER_NAME}-bmh.yaml" false
        log "INFO" "BMH $WORKER_NAME created"
    done

    log "INFO" "BMO worker provisioning initiated"
}

# ---------------------------------------------------------------------------
# Redfish direct provisioning path (new)
# ---------------------------------------------------------------------------
_provision_workers_redfish() {
    local count="$1"

    log "INFO" "Provisioning ${count} worker(s) via direct Redfish..."

    # Step 1: Verify Redfish connectivity for all workers first
    log "INFO" "Verifying Redfish connectivity for all workers..."
    for i in $(seq 1 "$count"); do
        _get_worker_config "$i" || return 1
        redfish_verify_connectivity "${WORKER_BMC_IP}" "${WORKER_BMC_USER}" "${WORKER_BMC_PASS}" || return 1
    done

    # Step 2: Ensure cluster is in day2 mode and get the ISO URL
    log "INFO" "Preparing Assisted Installer day2 environment..."
    create_day2_cluster || return 1

    local iso_url
    # Redfish VirtualMedia boot requires a full ISO — minimal ISOs may not be
    # UEFI-bootable on all BMC firmware versions.
    ISO_TYPE=full iso_url=$(get_iso "${CLUSTER_NAME}" "day2" "url") || {
        log "ERROR" "Failed to get day2 ISO URL"
        return 1
    }
    log "INFO" "Day2 ISO URL: ${iso_url}"

    # Step 2b: Download ISO to the HTTP server so BMCs can reach it.
    # BMCs on management networks typically can't reach external URLs (api.openshift.com).
    local iso_filename="${CLUSTER_NAME}-day2.iso"
    local http_iso_url
    http_iso_url=$(_download_iso_to_http "${iso_url}" "${iso_filename}") || return 1
    log "INFO" "ISO available at: ${http_iso_url}"

    # Step 2c: Snapshot existing hosts BEFORE booting so we only count new registrations.
    local cluster_id infra_env_id existing_host_ids
    cluster_id=$(get_day2_cluster_id) || return 1
    infra_env_id=$(get_day2_infra_env_id) || return 1
    existing_host_ids=$(aicli -o json list hosts 2>/dev/null \
        | jq -r --arg ieid "${infra_env_id}" \
          '[.[] | select(.infra_env_id == $ieid)] | map(.id) | join(",")') || existing_host_ids=""
    log "INFO" "Existing hosts in infra-env (will be excluded): ${existing_host_ids:-none}"

    # Step 3: Mount ISO and boot each worker via Redfish + IPMI
    # Track worker BMC info for post-provision cleanup (eject ISO after install)
    local -a worker_bmc_ips=() worker_bmc_users=() worker_bmc_passes=()
    for i in $(seq 1 "$count"); do
        _get_worker_config "$i" || return 1
        redfish_provision_worker \
            "${WORKER_BMC_IP}" "${WORKER_BMC_USER}" "${WORKER_BMC_PASS}" \
            "${http_iso_url}" "${WORKER_NAME}" || return 1
        worker_bmc_ips+=("${WORKER_BMC_IP}")
        worker_bmc_users+=("${WORKER_BMC_USER}")
        worker_bmc_passes+=("${WORKER_BMC_PASS}")
    done

    # Step 4: Wait for hosts to register in Assisted Installer

    log "INFO" "Waiting for ${count} NEW worker(s) to register in Assisted Installer..."
    _check_redfish_hosts_registered() {
        local registered
        registered=$(aicli -o json list hosts 2>/dev/null \
            | jq -r --arg ieid "${infra_env_id}" --arg existing "${existing_host_ids}" \
              '($existing | split(",")) as $skip |
               [.[] | select(.infra_env_id == $ieid
                        and (.status == "known" or .status == "known-unbound")
                        and (.id as $id | $skip | index($id) | not))] | length') || registered=0
        log "INFO" "New hosts registered: ${registered}/${count}"
        [ "${registered}" -ge "${count}" ]
    }
    if ! retry 60 30 _check_redfish_hosts_registered; then
        log "ERROR" "Timeout waiting for Redfish-provisioned host(s) to register in AI"
        log "ERROR" "Check BMC console — the servers may not have booted from the ISO correctly"
        return 1
    fi

    # Collect the new host IDs for bind/start
    local new_host_ids
    new_host_ids=$(aicli -o json list hosts 2>/dev/null \
        | jq -r --arg ieid "${infra_env_id}" --arg existing "${existing_host_ids}" \
          '($existing | split(",")) as $skip |
           .[] | select(.infra_env_id == $ieid
                    and (.status == "known" or .status == "known-unbound")
                    and (.id as $id | $skip | index($id) | not)) | .id')

    # Step 5: Bind and start installation for each NEW host
    for host_id in ${new_host_ids}; do
        log "INFO" "Binding host ${host_id} to cluster ${CLUSTER_NAME}..."
        aicli bind host "${host_id}" "${CLUSTER_NAME}" || true
    done

    # Wait briefly for bind to take effect, then start
    sleep 5
    for host_id in ${new_host_ids}; do
        local host_status
        host_status=$(aicli -o json list hosts 2>/dev/null \
            | jq -r --arg hid "${host_id}" '.[] | select(.id == $hid) | .status')
        if [ "${host_status}" = "known" ]; then
            log "INFO" "Starting installation for host ${host_id}..."
            aicli start host "${host_id}" || true
        else
            log "INFO" "Host ${host_id} status is '${host_status}', waiting for it to become 'known'..."
        fi
    done

    # Step 6: Wait for installation to complete
    log "INFO" "Waiting for ${count} host(s) to complete installation..."
    _check_redfish_hosts_installed() {
        # Retry start for hosts that are now "known" but haven't been started
        for host_id in ${new_host_ids}; do
            local hs
            hs=$(aicli -o json list hosts 2>/dev/null \
                | jq -r --arg hid "${host_id}" '.[] | select(.id == $hid) | .status')
            if [ "${hs}" = "known" ]; then
                log "INFO" "Retrying start for host ${host_id} (status: known)..."
                aicli start host "${host_id}" || true
            fi
        done
        local installed_count
        installed_count=$(aicli -o json list hosts 2>/dev/null \
            | jq -r --arg ieid "${infra_env_id}" --arg existing "${existing_host_ids}" \
              '($existing | split(",")) as $skip |
               [.[] | select(.infra_env_id == $ieid
                        and (.status == "installed" or .status == "added-to-existing-cluster")
                        and (.id as $id | $skip | index($id) | not))] | length') || installed_count=0
        log "INFO" "Hosts installed: ${installed_count}/${count}"
        [ "${installed_count}" -ge "${count}" ]
    }
    if ! retry 120 60 _check_redfish_hosts_installed; then
        log "ERROR" "Timeout waiting for Redfish-provisioned hosts to complete installation"
        return 1
    fi

    log "INFO" "All ${count} Redfish-provisioned worker(s) installed successfully"

    # Step 7: Eject virtual media from all BMCs
    # After installation the server reboots — without ejecting, it might boot from ISO again
    log "INFO" "Ejecting virtual media from all BMCs..."
    for idx in $(seq 0 $((count - 1))); do
        local mgr_path vm_cd_path
        mgr_path=$(redfish_get_manager_id "${worker_bmc_ips[$idx]}" "${worker_bmc_users[$idx]}" "${worker_bmc_passes[$idx]}") || continue
        vm_cd_path=$(redfish_find_cd_virtual_media "${worker_bmc_ips[$idx]}" "${worker_bmc_users[$idx]}" "${worker_bmc_passes[$idx]}" "${mgr_path}") || continue
        redfish_eject_iso "${worker_bmc_ips[$idx]}" "${worker_bmc_users[$idx]}" "${worker_bmc_passes[$idx]}" "${vm_cd_path}" || true
    done

    # Step 8: Approve CSRs and wait for workers to become Ready
    log "INFO" "Waiting for worker nodes to join the cluster..."
    _check_workers_ready() {
        # Approve any pending CSRs first
        approve_worker_csrs
        local ready_workers
        ready_workers=$(oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers 2>/dev/null \
            | grep -c ' Ready ' || true)
        local expected_total=$(( ${WORKER_COUNT:-0} ))
        log "INFO" "Worker nodes Ready: ${ready_workers}/${expected_total}"
        [ "${ready_workers}" -ge "${expected_total}" ]
    }
    if ! retry 40 30 _check_workers_ready; then
        log "WARN" "Timeout waiting for all workers to become Ready — check node status"
        log "WARN" "Workers may still be initializing (OVN/MCO). Run 'oc get nodes' to check."
        # Don't fail — installation succeeded, node just needs time
    fi

    log "INFO" "Redfish worker provisioning complete"
}

# ---------------------------------------------------------------------------
# Main entry point — dispatches to BMO or Redfish based on WORKER_PROVISION_METHOD
# ---------------------------------------------------------------------------
provision_all_workers() {
    local count="${WORKER_COUNT:-0}"
    [[ "$count" -eq 0 ]] && { log "INFO" "WORKER_COUNT=0, skipping"; return 0; }

    # Ensure kubeconfig is available
    get_kubeconfig

    # Apply short worker hostnames MachineConfig if enabled
    apply_short_worker_hostnames

    # Apply custom node labels MachineConfig if configured
    apply_worker_node_labels

    local method="${WORKER_PROVISION_METHOD:-bmo}"
    log "INFO" "Worker provisioning method: ${method}"

    case "${method}" in
        bmo)
            _provision_workers_bmo "${count}"
            ;;
        redfish)
            _provision_workers_redfish "${count}"
            ;;
        *)
            log "ERROR" "Unknown WORKER_PROVISION_METHOD: ${method} (expected: bmo or redfish)"
            return 1
            ;;
    esac

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
    apply-worker-node-labels) apply_worker_node_labels ;;
    deploy-csr-auto-approver) deploy_csr_auto_approver ;;
    delete-csr-auto-approver) delete_csr_auto_approver ;;
    *)
        echo "Usage: $0 {provision-all-workers|approve-worker-csrs|display-worker-status|display-manual-csr-instructions|apply-short-worker-hostnames|apply-worker-node-labels|deploy-csr-auto-approver|delete-csr-auto-approver}"
        exit 1
        ;;
esac
