#!/bin/bash
# redfish.sh - Direct Redfish-based baremetal provisioning (alternative to BMO/Ironic)
#
# Provisions baremetal worker nodes by talking directly to the BMC's Redfish API:
#   1. Mount ISO via VirtualMedia
#   2. Set one-time boot override to virtual CD
#   3. Power cycle the server
#
# This bypasses BareMetalHost CRDs and the Ironic provisioning backend entirely.
# The server boots from the Assisted Installer day2 ISO, registers with AI,
# and is then installed via `aicli start host`.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

# Redfish API timeout and retry settings
REDFISH_TIMEOUT=${REDFISH_TIMEOUT:-30}
REDFISH_VERIFY_SSL=${REDFISH_VERIFY_SSL:-false}

# Build curl flags for Redfish calls.
# Populates the caller's CURL_FLAGS array variable.
_redfish_curl_flags() {
    CURL_FLAGS=(-s -S --connect-timeout 10 --max-time "${REDFISH_TIMEOUT}")
    if [ "${REDFISH_VERIFY_SSL}" != "true" ]; then
        CURL_FLAGS+=(-k)
    fi
}

# Make a Redfish API call
# Usage: redfish_call <METHOD> <BMC_IP> <PATH> <USER> <PASS> [JSON_BODY]
redfish_call() {
    local method="$1"
    local bmc_ip="$2"
    local path="$3"
    local user="$4"
    local pass="$5"
    local body="${6:-}"

    local url="https://${bmc_ip}${path}"
    local CURL_FLAGS
    _redfish_curl_flags

    if [ -n "${body}" ]; then
        curl "${CURL_FLAGS[@]}" -X "${method}" -u "${user}:${pass}" \
            -H 'Content-Type: application/json' -d "${body}" "${url}" 2>&1
    else
        curl "${CURL_FLAGS[@]}" -X "${method}" -u "${user}:${pass}" \
            -H 'Content-Type: application/json' "${url}" 2>&1
    fi
}

# Get the first System ID from the Redfish service root
# Most servers have /redfish/v1/Systems/1 or /redfish/v1/Systems/System.Embedded.1
redfish_get_system_id() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"

    local response
    response=$(redfish_call GET "${bmc_ip}" "/redfish/v1/Systems" "${user}" "${pass}")

    local system_id
    system_id=$(echo "${response}" | jq -r '.Members[0]."@odata.id"' 2>/dev/null)

    if [ -z "${system_id}" ] || [ "${system_id}" = "null" ]; then
        log "ERROR" "Failed to get System ID from Redfish on ${bmc_ip}"
        log "ERROR" "Response: ${response}"
        return 1
    fi

    echo "${system_id}"
}

# Get the first Manager ID (for VirtualMedia operations)
redfish_get_manager_id() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"

    local response
    response=$(redfish_call GET "${bmc_ip}" "/redfish/v1/Managers" "${user}" "${pass}")

    local manager_id
    manager_id=$(echo "${response}" | jq -r '.Members[0]."@odata.id"' 2>/dev/null)

    if [ -z "${manager_id}" ] || [ "${manager_id}" = "null" ]; then
        log "ERROR" "Failed to get Manager ID from Redfish on ${bmc_ip}"
        log "ERROR" "Response: ${response}"
        return 1
    fi

    echo "${manager_id}"
}

# Find a VirtualMedia slot that supports CD/DVD media types
# Returns the VirtualMedia URI
# Tries the well-known "CD" slot first (Dell iDRAC, HPE iLO) to avoid
# enumerating all members — some slots (e.g. RemovableDisk) are slow to respond.
redfish_find_cd_virtual_media() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local manager_path="$4"

    # Fast path: try the well-known CD slot directly
    local cd_path="${manager_path}/VirtualMedia/CD"
    local detail
    detail=$(REDFISH_TIMEOUT=10 redfish_call GET "${bmc_ip}" "${cd_path}" "${user}" "${pass}" 2>/dev/null) || true
    if [ -n "${detail}" ]; then
        local media_types
        media_types=$(echo "${detail}" | jq -r '.MediaTypes[]?' 2>/dev/null)
        if echo "${media_types}" | grep -qiE "CD|DVD"; then
            echo "${cd_path}"
            return 0
        fi
    fi

    # Fallback: enumerate all VirtualMedia members
    local response
    response=$(redfish_call GET "${bmc_ip}" "${manager_path}/VirtualMedia" "${user}" "${pass}")

    local members
    members=$(echo "${response}" | jq -r '.Members[]."@odata.id"' 2>/dev/null)

    if [ -z "${members}" ]; then
        log "ERROR" "No VirtualMedia members found on ${bmc_ip}"
        return 1
    fi

    for member in ${members}; do
        # Skip the CD path we already tried
        [[ "${member}" == "${cd_path}" ]] && continue

        detail=$(redfish_call GET "${bmc_ip}" "${member}" "${user}" "${pass}")

        local media_types
        media_types=$(echo "${detail}" | jq -r '.MediaTypes[]?' 2>/dev/null)

        if echo "${media_types}" | grep -qiE "CD|DVD"; then
            echo "${member}"
            return 0
        fi
    done

    # If no CD/DVD type found, fall back to first slot (common on some BMCs)
    local first_member
    first_member=$(echo "${response}" | jq -r '.Members[0]."@odata.id"' 2>/dev/null)
    if [ -n "${first_member}" ] && [ "${first_member}" != "null" ]; then
        log "WARN" "No CD/DVD VirtualMedia found, falling back to first slot: ${first_member}"
        echo "${first_member}"
        return 0
    fi

    log "ERROR" "No usable VirtualMedia slot found on ${bmc_ip}"
    return 1
}

# Eject any currently mounted VirtualMedia
redfish_eject_virtual_media() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local vm_path="$4"

    log "INFO" "Ejecting existing VirtualMedia on ${bmc_ip}..."

    # Check if media is currently inserted
    local detail
    detail=$(redfish_call GET "${bmc_ip}" "${vm_path}" "${user}" "${pass}")

    local inserted
    inserted=$(echo "${detail}" | jq -r '.Inserted // false' 2>/dev/null)

    if [ "${inserted}" = "true" ]; then
        local response
        response=$(redfish_call POST "${bmc_ip}" "${vm_path}/Actions/VirtualMedia.EjectMedia" "${user}" "${pass}" '{}')
        log "INFO" "Ejected existing media from ${vm_path}"
        sleep 2
    else
        log "INFO" "No media currently inserted"
    fi
}

# Mount an ISO via Redfish VirtualMedia
# The ISO URL must be HTTP/HTTPS accessible from the BMC
redfish_mount_iso() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local iso_url="$4"
    local vm_path="$5"

    log "INFO" "Mounting ISO via VirtualMedia on ${bmc_ip}..."
    log "INFO" "  ISO URL: ${iso_url}"
    log "INFO" "  VirtualMedia path: ${vm_path}"

    # Eject any existing media first
    redfish_eject_virtual_media "${bmc_ip}" "${user}" "${pass}" "${vm_path}"

    # Insert the new media
    local body
    body=$(jq -n --arg url "${iso_url}" '{Image: $url, Inserted: true, WriteProtected: true}')

    local response
    response=$(redfish_call POST "${bmc_ip}" "${vm_path}/Actions/VirtualMedia.InsertMedia" "${user}" "${pass}" "${body}")

    # Verify insertion
    sleep 3
    local detail
    detail=$(redfish_call GET "${bmc_ip}" "${vm_path}" "${user}" "${pass}")

    local inserted
    inserted=$(echo "${detail}" | jq -r '.Inserted // false' 2>/dev/null)

    if [ "${inserted}" != "true" ]; then
        log "ERROR" "Failed to mount ISO on ${bmc_ip}. VirtualMedia not showing as inserted."
        log "ERROR" "InsertMedia response: ${response}"
        log "ERROR" "VirtualMedia status: ${detail}"
        return 1
    fi

    log "INFO" "ISO mounted successfully on ${bmc_ip}"
}

# Set one-time boot to virtual CD via Redfish API.
# Uses Redfish PATCH to set BootSourceOverrideTarget=Cd + BootSourceOverrideEnabled=Once.
# More reliable than IPMI raw commands on Dell iDRAC — IPMI bootdev cdrom doesn't
# consistently honor EFI boot on all firmware versions.
redfish_set_boot_cdrom() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local system_path="$4"

    log "INFO" "Setting one-time boot to CD-ROM via Redfish on ${bmc_ip}..."

    local response
    response=$(redfish_call PATCH "${bmc_ip}" "${system_path}" "${user}" "${pass}" \
        '{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once"}}') || {
        log "ERROR" "Redfish boot override failed on ${bmc_ip}"
        return 1
    }

    # Verify the override was applied
    local verify
    verify=$(redfish_call GET "${bmc_ip}" "${system_path}" "${user}" "${pass}") || true
    local target enabled
    target=$(echo "${verify}" | jq -r '.Boot.BootSourceOverrideTarget // "unknown"' 2>/dev/null)
    enabled=$(echo "${verify}" | jq -r '.Boot.BootSourceOverrideEnabled // "unknown"' 2>/dev/null)
    log "INFO" "Redfish boot override set: target=${target}, enabled=${enabled}"
}

# Power off via Redfish. Waits until the server is confirmed off.
# Silently succeeds if already off.
redfish_power_off() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local system_path="$4"

    local current_state
    current_state=$(redfish_get_power_state "${bmc_ip}" "${user}" "${pass}" "${system_path}")
    if [[ "${current_state}" == "Off" ]]; then
        log "INFO" "Server ${bmc_ip} is already off"
        return 0
    fi

    log "INFO" "Powering off ${bmc_ip} via Redfish..."
    redfish_power_action "${bmc_ip}" "${user}" "${pass}" "${system_path}" "ForceOff"

    local retries=0
    while [[ $retries -lt 30 ]]; do
        sleep 2
        current_state=$(redfish_get_power_state "${bmc_ip}" "${user}" "${pass}" "${system_path}")
        if [[ "${current_state}" == "Off" ]]; then
            log "INFO" "Server ${bmc_ip} is powered off"
            return 0
        fi
        retries=$((retries + 1))
    done
    log "WARN" "Server ${bmc_ip} may not have fully powered off — proceeding anyway"
}

# Power on via Redfish.
redfish_power_on() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local system_path="$4"

    log "INFO" "Powering on ${bmc_ip} via Redfish..."
    redfish_power_action "${bmc_ip}" "${user}" "${pass}" "${system_path}" "On"
    log "INFO" "Redfish power on command sent to ${bmc_ip}"
}

# Set one-time boot override to virtual CD via Redfish (fallback — unreliable on Dell iDRAC)
# Dell iDRAC issue: the Cd override is consumed but UEFI boot order may still boot from RAID
# if an existing OS is installed. Prefer IPMI bootdev when available.
redfish_set_boot_override_cd() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local system_path="$4"

    log "INFO" "Setting one-time boot override to virtual CD via Redfish on ${bmc_ip}..."
    log "WARN" "Redfish Cd boot override may be unreliable on Dell iDRAC — prefer IPMI"

    local body='{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once"}}'

    local response
    response=$(redfish_call PATCH "${bmc_ip}" "${system_path}" "${user}" "${pass}" "${body}")

    # Check for errors
    local error
    error=$(echo "${response}" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "${error}" ]; then
        log "ERROR" "Failed to set boot override on ${bmc_ip}: ${error}"
        return 1
    fi

    log "INFO" "Boot override set to virtual CD (one-time) on ${bmc_ip}"

    # Verify the override actually stuck
    local verify
    verify=$(redfish_call GET "${bmc_ip}" "${system_path}" "${user}" "${pass}")
    local actual_target
    actual_target=$(echo "${verify}" | jq -r '.Boot.BootSourceOverrideTarget // "unknown"' 2>/dev/null)
    if [ "${actual_target}" != "Cd" ]; then
        log "ERROR" "Boot override verification failed on ${bmc_ip}: target is '${actual_target}', expected 'Cd'"
        return 1
    fi
    log "INFO" "Boot override verified: target=${actual_target}"
}

# Eject the virtual CD ISO
redfish_eject_iso() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local vm_path="$4"

    log "INFO" "Ejecting virtual media on ${bmc_ip}..."
    local response
    response=$(redfish_call POST "${bmc_ip}" "${vm_path}/Actions/VirtualMedia.EjectMedia" "${user}" "${pass}" '{}')

    local error
    error=$(echo "${response}" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "${error}" ]; then
        # Not fatal — the CD might already be ejected
        log "WARN" "Eject returned error (may be already ejected): ${error}"
    else
        log "INFO" "Virtual media ejected on ${bmc_ip}"
    fi
}

# Get current power state
redfish_get_power_state() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local system_path="$4"

    local response
    response=$(redfish_call GET "${bmc_ip}" "${system_path}" "${user}" "${pass}")
    echo "${response}" | jq -r '.PowerState' 2>/dev/null
}

# Power action: On, ForceOff, GracefulShutdown, ForceRestart, GracefulRestart
redfish_power_action() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local system_path="$4"
    local action="$5"

    log "INFO" "Performing power action '${action}' on ${bmc_ip}..."

    local body
    body=$(jq -n --arg type "${action}" '{ResetType: $type}')

    local response
    response=$(redfish_call POST "${bmc_ip}" "${system_path}/Actions/ComputerSystem.Reset" "${user}" "${pass}" "${body}")

    local error
    error=$(echo "${response}" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "${error}" ]; then
        log "ERROR" "Power action '${action}' failed on ${bmc_ip}: ${error}"
        return 1
    fi

    log "INFO" "Power action '${action}' completed on ${bmc_ip}"
}

# Power off a server if it's currently on, wait for it to be off
redfish_power_off_if_on() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local system_path="$4"

    local current_state
    current_state=$(redfish_get_power_state "${bmc_ip}" "${user}" "${pass}" "${system_path}")
    log "INFO" "Current power state for ${bmc_ip}: ${current_state}"

    if [ "${current_state}" = "On" ]; then
        redfish_power_action "${bmc_ip}" "${user}" "${pass}" "${system_path}" "ForceOff"
        log "INFO" "Waiting for server to power off..."
        sleep 10

        # Verify it's off
        local retries=12
        while [ $retries -gt 0 ]; do
            current_state=$(redfish_get_power_state "${bmc_ip}" "${user}" "${pass}" "${system_path}")
            if [ "${current_state}" = "Off" ]; then
                break
            fi
            sleep 5
            ((retries--))
        done

        if [ "${current_state}" != "Off" ]; then
            log "WARN" "Server ${bmc_ip} did not power off cleanly (state: ${current_state}), proceeding anyway"
        fi
    fi
}

# Power cycle a server: force off if on, then power on
redfish_power_cycle() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local system_path="$4"

    local current_state
    current_state=$(redfish_get_power_state "${bmc_ip}" "${user}" "${pass}" "${system_path}")
    log "INFO" "Current power state for ${bmc_ip}: ${current_state}"

    if [ "${current_state}" = "On" ]; then
        redfish_power_action "${bmc_ip}" "${user}" "${pass}" "${system_path}" "ForceOff"
        log "INFO" "Waiting for server to power off..."
        sleep 10

        # Verify it's off
        local retries=12
        while [ $retries -gt 0 ]; do
            current_state=$(redfish_get_power_state "${bmc_ip}" "${user}" "${pass}" "${system_path}")
            if [ "${current_state}" = "Off" ]; then
                break
            fi
            sleep 5
            ((retries--))
        done

        if [ "${current_state}" != "Off" ]; then
            log "WARN" "Server ${bmc_ip} did not power off cleanly (state: ${current_state}), proceeding anyway"
        fi
    fi

    redfish_power_action "${bmc_ip}" "${user}" "${pass}" "${system_path}" "On"
    log "INFO" "Server ${bmc_ip} powered on"
}

# Full Redfish provisioning flow for a single worker:
#   1. Discover Redfish endpoints (System, Manager, VirtualMedia)
#   2. Mount ISO via VirtualMedia
#   3. Set boot to CD via IPMI (Redfish Cd override is unreliable on Dell)
#   4. Power cycle via IPMI
redfish_provision_worker() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"
    local iso_url="$4"
    local worker_name="$5"

    log "INFO" "========================================"
    log "INFO" "Provisioning ${worker_name} via Redfish"
    log "INFO" "  BMC: ${bmc_ip}"
    log "INFO" "========================================"

    # Step 1: Discover endpoints
    log "INFO" "Discovering Redfish endpoints..."
    local system_path manager_path vm_path

    system_path=$(redfish_get_system_id "${bmc_ip}" "${user}" "${pass}") || return 1
    log "INFO" "  System: ${system_path}"

    manager_path=$(redfish_get_manager_id "${bmc_ip}" "${user}" "${pass}") || return 1
    log "INFO" "  Manager: ${manager_path}"

    vm_path=$(redfish_find_cd_virtual_media "${bmc_ip}" "${user}" "${pass}" "${manager_path}") || return 1
    log "INFO" "  VirtualMedia (CD): ${vm_path}"

    # Step 2: Power off first (ensures clean state for VirtualMedia mount)
    # Dell iDRAC may eject VirtualMedia during power transitions,
    # so we power off first, then mount ISO while the server is off.
    redfish_power_off "${bmc_ip}" "${user}" "${pass}" "${system_path}"

    # Step 3: Mount ISO (while server is off — prevents ejection on power transition)
    redfish_mount_iso "${bmc_ip}" "${user}" "${pass}" "${iso_url}" "${vm_path}" || return 1

    # Step 4: Set boot override to CD via Redfish (while server is off)
    redfish_set_boot_cdrom "${bmc_ip}" "${user}" "${pass}" "${system_path}" || return 1

    # Step 5: Power on via Redfish
    redfish_power_on "${bmc_ip}" "${user}" "${pass}" "${system_path}" || return 1

    log "INFO" "Server ${bmc_ip} powered on — booting from virtual CD"
    log "INFO" "Redfish provisioning initiated for ${worker_name}"
    log "INFO" "Server will boot from ISO and register with Assisted Installer"
}

# Verify Redfish connectivity to a BMC
redfish_verify_connectivity() {
    local bmc_ip="$1"
    local user="$2"
    local pass="$3"

    log "INFO" "Verifying Redfish connectivity to ${bmc_ip}..."

    local response
    response=$(redfish_call GET "${bmc_ip}" "/redfish/v1" "${user}" "${pass}")

    local product
    product=$(echo "${response}" | jq -r '.Product // .RedfishVersion // empty' 2>/dev/null)

    if [ -z "${product}" ]; then
        log "ERROR" "Cannot reach Redfish API on ${bmc_ip}"
        log "ERROR" "Response: ${response}"
        return 1
    fi

    local version
    version=$(echo "${response}" | jq -r '.RedfishVersion // "unknown"' 2>/dev/null)
    log "INFO" "Redfish connectivity OK (version: ${version})"
}

# Command dispatcher — only runs when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
case "${1:-}" in
    provision-worker) shift; redfish_provision_worker "$@" ;;
    verify-connectivity) shift; redfish_verify_connectivity "$@" ;;
    get-power-state)
        shift
        bmc_ip="$1"; user="$2"; pass="$3"
        system_path=$(redfish_get_system_id "${bmc_ip}" "${user}" "${pass}")
        redfish_get_power_state "${bmc_ip}" "${user}" "${pass}" "${system_path}"
        ;;
    power-action)
        shift
        bmc_ip="$1"; user="$2"; pass="$3"; action="$4"
        system_path=$(redfish_get_system_id "${bmc_ip}" "${user}" "${pass}")
        redfish_power_action "${bmc_ip}" "${user}" "${pass}" "${system_path}" "${action}"
        ;;
    *)
        echo "Usage: $0 {provision-worker|verify-connectivity|get-power-state|power-action}"
        exit 1
        ;;
esac
fi
