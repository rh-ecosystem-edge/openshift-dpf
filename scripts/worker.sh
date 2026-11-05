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
    output=$(ipmitool -I lanplus -H "${bmc_ip}" -U "${user}" -f "${pw_file}" "$@") || status=$?
    
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
    # Existing .env files may predate the flag; keep power-off enabled by default.
    if [[ "${POWER_OFF_WORKERS:-true}" == "false" ]]; then
        log "INFO" "POWER_OFF_WORKERS=false, skipping physical worker shutoff"
        return 0
    fi

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

poweron_workers() {
    local wait_for_readiness="${1:-true}"
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

    if [ "${wait_for_readiness}" != "true" ]; then
        return 0
    fi

    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        wait_for_zero_trust_dpu_redfish
        return
    fi

    validate_worker_power_on_delay || return 1

    log "INFO" "Waiting ${WORKER_POWER_ON_DELAY}s for worker hosts/DPUs to settle before provisioning..."
    sleep "${WORKER_POWER_ON_DELAY}"
}

# NNO only: regular ovnkube-node builds br-ex from the boot NIC on first start,
# so jumbo MTU must already be in CoreOS. DPF DPU-host workers do not take this
# path (overlay lives on the DPU; DPUFlavor / DPFOperatorConfig MTU is applied
# later). Match the boot NIC by WORKER_n_BOOT_MAC.
# Apply the network-data Secret before the BMH. If the BMH already exists,
# provision_all_workers skips that worker; a new MTU or boot MAC needs a full
# reprovision (the node leaves the cluster).
maybe_attach_nno_jumbo_mtu() {
    local name="$1"
    local boot_mac="$2"
    local bmh_file="$3"

    is_nno_profile || return 0
    [ -n "${NODES_MTU:-}" ] && [ "${NODES_MTU}" != "1500" ] || return 0

    log "INFO" "Attaching jumbo-frame NMState for $name (mtu: ${NODES_MTU}, mac: $boot_mac)"
    process_template \
        "${WORKER_TEMPLATE_DIR}/network-data-secret.yaml" \
        "${WORKER_GENERATED_DIR}/${name}-network-data.yaml" \
        "<WORKER_NAME>" "$name" \
        "<BOOT_MAC>" "$boot_mac" \
        "<NODES_MTU>" "$NODES_MTU"

    cat >> "$bmh_file" << EOF
  preprovisioningNetworkDataName: ${name}-network-data
EOF

    retry 5 10 apply_manifest "${WORKER_GENERATED_DIR}/${name}-network-data.yaml" true
}

_dpu_redfish_ready() {
    local ip="$1"
    local curl_config="$2"

    curl --config "${curl_config}" \
        --insecure \
        --silent \
        --fail \
        --connect-timeout 5 \
        --max-time 10 \
        --output /dev/null \
        "https://${ip}/redfish/v1/Systems/Bluefield"
}

wait_for_zero_trust_dpu_redfish() {
    if [ "${DPF_DEPLOYMENT_MODE}" != "zero-trust" ]; then
        return 0
    fi
    wait_for_dpu_redfish
}

# Print every DPU BMC IP in WORKER_<N>_DPU_BMC_IPS, one per line.
list_all_dpu_bmc_ips() {
    local host
    while IFS= read -r host; do
        list_zero_trust_host_dpu_bmc_ips "${host}"
    done < <(list_zero_trust_dpu_hosts)
}

# Wait until every DPU BMC in WORKER_<N>_DPU_BMC_IPS answers Redfish, for at
# most WORKER_POWER_ON_DELAY seconds.
wait_for_dpu_redfish() {
    local -a bmc_ips=()
    mapfile -t bmc_ips < <(list_all_dpu_bmc_ips)
    local expected="${#bmc_ips[@]}"
    if [ "${expected}" -eq 0 ]; then
        log "ERROR" "No WORKER_<N>_DPU_BMC_IPS are configured for DPU Redfish readiness"
        return 1
    fi

    local curl_config escaped_password
    curl_config=$(mktemp "${TMPDIR:-/tmp}/dpu-redfish-curl.XXXXXX")
    chmod 600 "${curl_config}"
    trap 'rm -f "${curl_config}"' EXIT
    escaped_password="${ZT_DPU_BMC_ROOT_PASSWORD//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"
    printf 'user = "root:%s"\n' "${escaped_password}" > "${curl_config}"

    local interval=10
    local started_at current_time elapsed reachable ip
    started_at=$(date +%s)

    log "INFO" "Waiting up to ${WORKER_POWER_ON_DELAY}s for ${expected} configured DPU Redfish endpoint(s)..."
    while true; do
        reachable=0
        for ip in "${bmc_ips[@]}"; do
            if _dpu_redfish_ready "${ip}" "${curl_config}"; then
                reachable=$((reachable + 1))
            fi
        done

        if [ "${reachable}" -ge "${expected}" ]; then
            rm -f "${curl_config}"
            trap - EXIT
            log "INFO" "All ${expected} configured DPU Redfish endpoint(s) are ready"
            return 0
        fi

        current_time=$(date +%s)
        elapsed=$((current_time - started_at))
        if [ "${elapsed}" -ge "${WORKER_POWER_ON_DELAY}" ]; then
            rm -f "${curl_config}"
            trap - EXIT
            log "ERROR" "Only ${reachable}/${expected} configured DPU Redfish endpoint(s) became ready within ${WORKER_POWER_ON_DELAY}s"
            return 1
        fi

        log "INFO" "DPU Redfish readiness: ${reachable}/${expected}; retrying in ${interval}s..."
        sleep "${interval}"
    done
}

HOST_RSHIM_PATH="redfish/v1/Systems/Bluefield/Oem/Nvidia"
HOST_RSHIM_SET_PATH="${HOST_RSHIM_PATH}/Actions/HostRshim.Set"
HOST_PRIVILEGE_PATH="redfish/v1/Chassis/Card1/NetworkAdapters/NvidiaNetworkAdapter/Oem/Nvidia/HostPrivilegeConfig"
HOST_PRIVILEGE_SETTINGS_PATH="${HOST_PRIVILEGE_PATH}/Settings"

# Run curl against a DPU BMC with the root credentials in curl_config.
_dpu_bmc_curl() {
    local curl_config="$1"
    shift
    curl --config "${curl_config}" --insecure --silent --connect-timeout 5 --max-time 20 "$@"
}

# Send a JSON body with METHOD to a DPU BMC path and print the HTTP status.
_dpu_bmc_write() {
    local curl_config="$1" ip="$2" method="$3" path="$4" body="$5"
    _dpu_bmc_curl "${curl_config}" --output /dev/null --write-out '%{http_code}' \
        -X "${method}" -H 'Content-Type: application/json' -d "${body}" \
        "https://${ip}/${path}"
}

# Zero Trust disables host RShim through the DPU BMC and restricts the host
# with mlxprivhost on the DPU Arm. Host-trusted installs the DPU OS from the host
# over RShim, and the DPU agent only lifts the restriction after that install, so
# before a host-trusted install turn both back on through every DPU BMC in
# WORKER_<N>_DPU_BMC_IPS (BlueField-3). Both apply at the next host power cycle;
# until then HostRshim keeps its old value, and HostPrivilegeConfig/Settings can
# read Privileged while the host is still restricted. So unless every BMC
# already has both in force, the writes are sent every time. The DPU BMCs are
# down while their host is off, so each host is powered on first and, after the
# writes, off again; add-worker-nodes powers it on.
restore_host_trusted_dpus() {
    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        return 0
    fi
    if [ "${SKIP_HOST_RSHIM_RESTORE:-false}" = "true" ]; then
        log "WARN" "SKIP_HOST_RSHIM_RESTORE=true, not turning host RShim back on"
        return 0
    fi

    local -a hosts=() bmc_ips=()
    mapfile -t hosts < <(list_zero_trust_dpu_hosts)
    mapfile -t bmc_ips < <(list_all_dpu_bmc_ips)
    if [ "${#bmc_ips[@]}" -eq 0 ]; then
        log "INFO" "No WORKER_<N>_DPU_BMC_IPS configured, skipping host RShim restore"
        return 0
    fi
    if [ -z "${ZT_DPU_BMC_ROOT_PASSWORD:-}" ]; then
        log "ERROR" "WORKER_<N>_DPU_BMC_IPS is set but ZT_DPU_BMC_ROOT_PASSWORD is not; cannot restore host RShim"
        return 1
    fi
    if [[ "${ZT_DPU_BMC_ROOT_PASSWORD}" == *$'\n'* || "${ZT_DPU_BMC_ROOT_PASSWORD}" == *$'\r'* ]]; then
        log "ERROR" "ZT_DPU_BMC_ROOT_PASSWORD must not contain a line break"
        return 1
    fi
    local ip
    for ip in "${bmc_ips[@]}"; do
        if ! [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            log "ERROR" "WORKER_<N>_DPU_BMC_IPS entry '${ip}' is not an IPv4 address"
            return 1
        fi
    done
    validate_worker_power_on_delay || return 1

    local host
    for host in "${hosts[@]}"; do
        _poweron_worker "${host}" || return 1
    done
    wait_for_dpu_redfish || return 1

    local curl_config escaped_password
    curl_config=$(mktemp "${TMPDIR:-/tmp}/dpu-redfish-curl.XXXXXX")
    chmod 600 "${curl_config}"
    trap 'rm -f "${curl_config}"' EXIT
    escaped_password="${ZT_DPU_BMC_ROOT_PASSWORD//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"
    printf 'user = "root:%s"\n' "${escaped_password}" > "${curl_config}"

    local state code mode trusted=true
    local -a failed=()
    for ip in "${bmc_ips[@]}"; do
        state=$(_dpu_bmc_curl "${curl_config}" "https://${ip}/${HOST_RSHIM_PATH}" \
            | jq -r '.HostRshim // empty' 2>/dev/null) || state=""
        if [ "${state}" != "Enabled" ] && [ "${state}" != "Disabled" ]; then
            log "ERROR" "${ip}: HostRshim reads '${state:-no answer}'; no DPU BMC was changed"
            rm -f "${curl_config}"
            trap - EXIT
            return 1
        fi
        mode=$(_dpu_bmc_curl "${curl_config}" "https://${ip}/${HOST_PRIVILEGE_PATH}" \
            | jq -r '.PrivilegeMode // empty' 2>/dev/null) || mode=""
        if [ -z "${mode}" ]; then
            log "ERROR" "${ip}: host privilege reads 'no answer'; no DPU BMC was changed"
            rm -f "${curl_config}"
            trap - EXIT
            return 1
        fi
        log "INFO" "${ip}: HostRshim ${state}, host privilege ${mode}"
        if [ "${state}" != "Enabled" ] || [ "${mode}" != "Privileged" ]; then
            trusted=false
        fi
    done
    if [ "${trusted}" = "true" ]; then
        rm -f "${curl_config}"
        trap - EXIT
        log "INFO" "Every DPU BMC already has host RShim Enabled and host privilege Privileged in force; nothing to restore"
        return 0
    fi

    for ip in "${bmc_ips[@]}"; do
        code=$(_dpu_bmc_write "${curl_config}" "${ip}" POST "${HOST_RSHIM_SET_PATH}" '{"HostRshim":"Enabled"}') || code=""
        if ! [[ "${code}" =~ ^2[0-9]{2}$ ]]; then
            log "ERROR" "${ip}: POST HostRshim.Set Enabled returned ${code:-no answer}"
            failed+=("${ip}")
            continue
        fi
        code=$(_dpu_bmc_write "${curl_config}" "${ip}" PATCH "${HOST_PRIVILEGE_SETTINGS_PATH}" '{"PrivilegeMode":"Privileged"}') || code=""
        if ! [[ "${code}" =~ ^2[0-9]{2}$ ]]; then
            log "ERROR" "${ip}: PATCH host privilege Privileged returned ${code:-no answer}"
            failed+=("${ip}")
            continue
        fi
        mode=$(_dpu_bmc_curl "${curl_config}" "https://${ip}/${HOST_PRIVILEGE_SETTINGS_PATH}" \
            | jq -r '.PrivilegeMode // empty' 2>/dev/null) || mode=""
        if [ "${mode}" != "Privileged" ]; then
            log "ERROR" "${ip}: host privilege Settings reads '${mode:-no answer}' after the PATCH"
            failed+=("${ip}")
            continue
        fi
        log "INFO" "${ip}: host RShim Enabled and host privilege Privileged requested"
    done
    rm -f "${curl_config}"
    trap - EXIT

    if [ "${#failed[@]}" -gt 0 ]; then
        log "ERROR" "Could not request host RShim and host privilege on DPU BMC ${failed[*]}."
        log "ERROR" "Make both changes on each listed DPU BMC while its host is on, then power off every DPU host (worker(s) ${hosts[*]}) and rerun with SKIP_HOST_RSHIM_RESTORE=true:"
        log "ERROR" "  POST {\"HostRshim\":\"Enabled\"} to https://<dpu-bmc>/${HOST_RSHIM_SET_PATH}"
        log "ERROR" "  PATCH {\"PrivilegeMode\":\"Privileged\"} to https://<dpu-bmc>/${HOST_PRIVILEGE_SETTINGS_PATH}"
        return 1
    fi

    log "INFO" "Powering off the DPU hosts so the next power-on applies host RShim and host privilege"
    local -a not_off=()
    for host in "${hosts[@]}"; do
        _shutoff_worker "${host}" || not_off+=("${host}")
    done
    if [ "${#not_off[@]}" -gt 0 ]; then
        log "ERROR" "Could not power off worker(s) ${not_off[*]}; power them off so the next power-on applies host RShim and host privilege"
        return 1
    fi
}

HOST_PRIVILEGE_DEFAULT_BODY='{"PrivilegeSettings":{"FirmwareUpdate":"Default","FlashAccess":"Default","GlobalParametersAccess":"Default","HostParametersAccess":"Default","InternalCPUAccess":"Default","NicReset":"Default","PccUpdate":"Default","PortAccess":"Default","HostPrivilegeLevel":"Privileged","ManagementInterfaceEnabled":true,"PortOwnerEnabled":true,"ReadCountersEnabled":true,"TracerEnabled":true}}'
HOST_PRIVILEGE_CONTROLS='["FirmwareUpdate","FlashAccess","GlobalParametersAccess","HostParametersAccess","InternalCPUAccess","NicReset","PccUpdate","PortAccess"]'
# Print the granular host privilege controls that are Enabled (or, for the
# second filter, not Default), comma separated, or "none"; print nothing when
# the answer lacks one of them.
HOST_PRIVILEGE_ENABLED_JQ="${HOST_PRIVILEGE_CONTROLS}"' as $k | .PrivilegeSettings as $s
  | if ($s | type) == "object" and all($k[]; ($s[.] | type) == "string")
    then [$k[] | select($s[.] == "Enabled")] | if length == 0 then "none" else join(",") end
    else empty end'
HOST_PRIVILEGE_NOT_DEFAULT_JQ="${HOST_PRIVILEGE_CONTROLS}"' as $k | .PrivilegeSettings as $s
  | if ($s | type) == "object" and all($k[]; ($s[.] | type) == "string")
    then [$k[] | select($s[.] != "Default")] | if length == 0 then "none" else join(",") end
    else empty end'

# Write a curl config with the DPU BMC root credentials and print its path.
_dpu_bmc_curl_config() {
    local curl_config escaped_password
    curl_config=$(mktemp "${TMPDIR:-/tmp}/dpu-redfish-curl.XXXXXX")
    chmod 600 "${curl_config}"
    escaped_password="${ZT_DPU_BMC_ROOT_PASSWORD//\\/\\\\}"
    escaped_password="${escaped_password//\"/\\\"}"
    printf 'user = "root:%s"\n' "${escaped_password}" > "${curl_config}"
    echo "${curl_config}"
}

# The {"PrivilegeMode":"Privileged"} preset restore_host_trusted_dpus sends sets
# the granular host privilege controls to Enabled. While one is Enabled the DPU
# rejects the mlxprivhost host restriction of a Zero Trust install, which then
# stays in DPU Config. A host-trusted DPU install clears them, so they stay
# Enabled only when no install ran after the restore. Before a Zero Trust
# install, set them to Default on every DPU BMC whose HostPrivilegeConfig or
# Settings has one Enabled. Only hosts with one Enabled in force are power
# cycled, so a running Zero Trust host never is. Runs after poweron-workers,
# while the DPU BMCs answer.
reset_dpu_privilege_controls() {
    if [ "${DPF_DEPLOYMENT_MODE}" != "zero-trust" ]; then
        return 0
    fi

    local -a hosts=()
    mapfile -t hosts < <(list_zero_trust_dpu_hosts)
    if [ "${#hosts[@]}" -eq 0 ]; then
        log "INFO" "No WORKER_<N>_DPU_BMC_IPS configured, skipping the host privilege control check"
        return 0
    fi

    local curl_config
    curl_config=$(_dpu_bmc_curl_config)
    trap 'rm -f "${curl_config}"' EXIT

    local host ip in_force pending
    local -a reset_ips=() cycle_ips=() cycle_hosts=() failed=()
    for host in "${hosts[@]}"; do
        while IFS= read -r ip; do
            in_force=$(_dpu_bmc_curl "${curl_config}" "https://${ip}/${HOST_PRIVILEGE_PATH}" \
                | jq -r "${HOST_PRIVILEGE_ENABLED_JQ}" 2>/dev/null) || in_force=""
            pending=$(_dpu_bmc_curl "${curl_config}" "https://${ip}/${HOST_PRIVILEGE_SETTINGS_PATH}" \
                | jq -r "${HOST_PRIVILEGE_ENABLED_JQ}" 2>/dev/null) || pending=""
            if [ -z "${in_force}" ] || [ -z "${pending}" ]; then
                log "ERROR" "${ip}: host privilege controls are not readable; no DPU BMC was changed"
                rm -f "${curl_config}"
                trap - EXIT
                return 1
            fi
            if [ "${in_force}" = "none" ] && [ "${pending}" = "none" ]; then
                continue
            fi
            log "INFO" "${ip}: host privilege controls Enabled in force: ${in_force}, pending: ${pending}"
            reset_ips+=("${ip}")
            if [ "${in_force}" != "none" ]; then
                cycle_ips+=("${ip}")
                if [ "${#cycle_hosts[@]}" -eq 0 ] || [ "${cycle_hosts[-1]}" != "${host}" ]; then
                    cycle_hosts+=("${host}")
                fi
            fi
        done < <(list_zero_trust_host_dpu_bmc_ips "${host}")
    done
    if [ "${#reset_ips[@]}" -eq 0 ]; then
        rm -f "${curl_config}"
        trap - EXIT
        log "INFO" "No DPU BMC has a granular host privilege control Enabled"
        return 0
    fi

    local code
    for ip in "${reset_ips[@]}"; do
        code=$(_dpu_bmc_write "${curl_config}" "${ip}" PATCH "${HOST_PRIVILEGE_SETTINGS_PATH}" "${HOST_PRIVILEGE_DEFAULT_BODY}") || code=""
        if ! [[ "${code}" =~ ^2[0-9]{2}$ ]]; then
            log "ERROR" "${ip}: PATCH host privilege controls Default returned ${code:-no answer}"
            failed+=("${ip}")
            continue
        fi
        pending=$(_dpu_bmc_curl "${curl_config}" "https://${ip}/${HOST_PRIVILEGE_SETTINGS_PATH}" \
            | jq -r "${HOST_PRIVILEGE_NOT_DEFAULT_JQ}" 2>/dev/null) || pending=""
        if [ "${pending}" != "none" ]; then
            log "ERROR" "${ip}: host privilege Settings has '${pending:-no answer}' not Default after the PATCH"
            failed+=("${ip}")
            continue
        fi
        log "INFO" "${ip}: granular host privilege controls Default requested"
    done
    rm -f "${curl_config}"
    trap - EXIT
    if [ "${#failed[@]}" -gt 0 ]; then
        log "ERROR" "Could not set the host privilege controls to Default on DPU BMC ${failed[*]}."
        log "ERROR" "PATCH ${HOST_PRIVILEGE_DEFAULT_BODY} to https://<dpu-bmc>/${HOST_PRIVILEGE_SETTINGS_PATH} on each, then power cycle its host"
        return 1
    fi
    if [ "${#cycle_hosts[@]}" -eq 0 ]; then
        log "INFO" "No host privilege control is Enabled in force; no power cycle needed"
        return 0
    fi

    log "INFO" "Power cycling worker(s) ${cycle_hosts[*]} so the host privilege controls apply"
    for host in "${cycle_hosts[@]}"; do
        _shutoff_worker "${host}" || return 1
    done
    for host in "${cycle_hosts[@]}"; do
        _poweron_worker "${host}" || return 1
    done
    wait_for_dpu_redfish || return 1

    # Redfish can answer before the NIC record is current, so retry for 2 minutes.
    local attempt
    local -a not_applied=()
    curl_config=$(_dpu_bmc_curl_config)
    trap 'rm -f "${curl_config}"' EXIT
    for attempt in 1 2 3 4 5 6; do
        not_applied=()
        for ip in "${cycle_ips[@]}"; do
            in_force=$(_dpu_bmc_curl "${curl_config}" "https://${ip}/${HOST_PRIVILEGE_PATH}" \
                | jq -r "${HOST_PRIVILEGE_NOT_DEFAULT_JQ}" 2>/dev/null) || in_force=""
            if [ "${in_force}" != "none" ]; then
                not_applied+=("${ip} (${in_force:-no answer})")
            fi
        done
        if [ "${#not_applied[@]}" -eq 0 ]; then
            break
        fi
        if [ "${attempt}" -lt 6 ]; then
            sleep 20
        fi
    done
    rm -f "${curl_config}"
    trap - EXIT
    if [ "${#not_applied[@]}" -gt 0 ]; then
        log "ERROR" "Host privilege controls not Default in force after the power cycle on DPU BMC ${not_applied[*]}; the Zero Trust install would stay in DPU Config"
        return 1
    fi
    log "INFO" "Granular host privilege controls are Default in force on every power cycled DPU BMC"
}

provision_all_workers() {
    if [[ "${DPF_DEPLOYMENT_MODE}" == "zero-trust" ]]; then
        log "ERROR" "add-worker-nodes is a host-trusted operation; Zero Trust discovers and provisions DPUs through Redfish/OOB during deploy-dpf"
        return 1
    fi

    local count="${WORKER_COUNT:-0}"
    [[ "$count" -eq 0 ]] && { log "INFO" "WORKER_COUNT=0, skipping"; return 0; }

    # Ensure kubeconfig is available
    get_kubeconfig

    # Count DPU workers (used for MachineSet replica count)
    local dpu_count=0
    for i in $(seq 1 "$count"); do
        local dpu_var="WORKER_${i}_DPU"
        [[ "${!dpu_var:-$(default_worker_is_dpu)}" == "true" ]] && ((dpu_count++)) || true
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

        # Skip if already exists (idempotent). Existing BMHs are not updated, so a
        # changed NODES_MTU or WORKER_n_BOOT_MAC needs a full reprovision; the node
        # leaves the cluster. delete_worker removes the BareMetalHost and the Node.
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
        local dpu_var="WORKER_${i}_DPU"; local is_dpu="${!dpu_var:-$(default_worker_is_dpu)}"

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

        local bmh_inspection_mode="disabled"
        if [[ "${BMH_ENABLE_INSPECTION}" == "true" ]]; then
            bmh_inspection_mode="agent"
        fi

        # Generate BareMetalHost using appropriate template
        process_template \
            "${WORKER_TEMPLATE_DIR}/$filename" \
            "${WORKER_GENERATED_DIR}/${name}-bmh.yaml" \
            "<WORKER_NAME>" "$name" \
            "<BOOT_MAC>" "$boot_mac" \
            "<BMC_IP>" "$bmc_ip" \
            "<ROOT_DEVICE>" "$root_dev" \
            "<BMH_INSPECTION_MODE>" "$bmh_inspection_mode"

        maybe_attach_nno_jumbo_mtu "$name" "$boot_mac" "${WORKER_GENERATED_DIR}/${name}-bmh.yaml"

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

    oc delete secret -n openshift-machine-api "${bmh_name}-network-data" --ignore-not-found
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
    shutoff-all-workers) shutoff_all_workers ;;
    poweron-workers) poweron_workers ;;
    poweron-all-workers) poweron_workers false ;;
    wait-for-dpu-redfish) wait_for_zero_trust_dpu_redfish ;;
    restore-host-trusted-dpus) restore_host_trusted_dpus ;;
    reset-dpu-privilege-controls) reset_dpu_privilege_controls ;;
    *)
        echo "Usage: $0 {provision-all-workers|approve-worker-csrs|display-worker-status|display-manual-csr-instructions|apply-short-worker-hostnames|deploy-csr-auto-approver|delete-csr-auto-approver|delete-worker <bmh-name|machine-name|node-name>|shutoff-all-workers|poweron-workers|poweron-all-workers|wait-for-dpu-redfish|restore-host-trusted-dpus|reset-dpu-privilege-controls}"
        exit 1
        ;;
esac
