#!/bin/bash
# preinstall-validate.sh - Pre-installation network validation
#
# Validates that no IPs in the HBN_OVN_NETWORK subnet are already in use.
# Uses nmap host discovery (-sn) to ping-sweep the subnet.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

# -----------------------------------------------------------------------------
# Validate HBN OVN Network IPs are free
# -----------------------------------------------------------------------------
validate_hbn_ovn_network() {
    local network="${HBN_OVN_NETWORK}"

    if [ -z "$network" ]; then
        log "ERROR" "HBN_OVN_NETWORK is not set"
        return 1
    fi

    log "INFO" "Validating that no IPs are in use in HBN_OVN_NETWORK=${network} ..."

    if ! command -v nmap &>/dev/null; then
        log "ERROR" "nmap is required but not installed"
        return 1
    fi

    local nmap_output
    if ! nmap_output=$(sudo nmap -sn "$network" -oG - 2>&1); then
        log "ERROR" "nmap scan failed for ${network}: ${nmap_output}"
        return 1
    fi

    local alive_hosts
    alive_hosts=$(awk '/Status: Up/ {print $2}' <<< "$nmap_output")

    if [ -z "$alive_hosts" ]; then
        log "INFO" "All IPs in ${network} are free"
        return 0
    fi

    local count
    count=$(echo "$alive_hosts" | wc -l | tr -d '[:space:]')

    log "ERROR" "Found ${count} host(s) responding in ${network}:"
    while IFS= read -r ip; do
        log "ERROR" "  ${ip} is in use"
    done <<< "$alive_hosts"

    log "ERROR" "HBN_OVN_NETWORK subnet is not free — resolve IP conflicts before deploying DPF"
    return 1
}

# -----------------------------------------------------------------------------
# Command Dispatcher
# -----------------------------------------------------------------------------
case "${1:-}" in
    validate-hbn-network) validate_hbn_ovn_network ;;
    *)
        echo "Usage: $0 {validate-hbn-network}"
        exit 1
        ;;
esac
