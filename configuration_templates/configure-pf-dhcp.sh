#!/bin/bash
set -e
#
# Configure DPU PF interfaces with DHCP and MTU using nmstatectl
#
# Reads PF interface names from NFD (Node Feature Discovery) features file:
#   /etc/kubernetes/node-feature-discovery/features.d/dpu
#
# MTU is automatically read from br-dpu bridge to ensure consistency
#

NFD_DPU_FEATURES_FILE="/etc/kubernetes/node-feature-discovery/features.d/dpu"
WAIT_INTERVAL=5  # Check interval in seconds
LOG_EVERY=6      # Log every Nth attempt (every 30s with 5s interval)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Generic wait function
# Usage: wait_for <description> <check_command...>
# Loops until check_command succeeds (returns 0)
wait_for() {
    local desc=$1
    shift
    local attempt=1
    log "Waiting for ${desc}..."
    while ! "$@"; do
        if (( attempt % LOG_EVERY == 0 )); then
            log "Still waiting for ${desc}... (Attempt $attempt)"
        fi
        sleep $WAIT_INTERVAL
        attempt=$((attempt + 1))
    done
    log "${desc} - ready."
}

# Get MTU from br-dpu bridge
get_bridge_mtu() {
    if ip link show br-dpu &>/dev/null; then
        ip link show br-dpu | grep -oP 'mtu \K[0-9]+'
    else
        echo ""
    fi
}

# Function to find PF interfaces from NFD DPU features file
find_pf_interfaces() {
    local pf_interfaces=()

    # Read PF names from entries like: dpu-X-pfY-name=<interface_name>
    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^dpu-[0-9]+-pf[0-9]+-name$ ]] && [ -n "$value" ]; then
            pf_interfaces+=("$value")
        fi
    done < <(tr -d '\r' < "$NFD_DPU_FEATURES_FILE")

    echo "${pf_interfaces[@]}"
}

# Helper checks used with wait_for
check_bridge()        { ip link show br-dpu &>/dev/null; }
check_nfd_file()      { [ -f "$NFD_DPU_FEATURES_FILE" ]; }
check_pf_interfaces() { [ "$(find_pf_interfaces | wc -w)" -gt 0 ]; }
check_nm_interface()  { nmstatectl show "$1" &>/dev/null; }

# Function to configure PF interface with DHCP and MTU using nmstatectl
configure_pf_interface() {
    local pf_name=$1
    local pf_mtu=$2

    wait_for "NM to manage $pf_name" check_nm_interface "$pf_name"

    log "Configuring PF interface: $pf_name with MTU: $pf_mtu"

    local pf_config_file
    pf_config_file=$(mktemp)

    cat > "$pf_config_file" << EOF
interfaces:
  - name: $pf_name
    type: ethernet
    state: up
    mtu: $pf_mtu
    ipv4:
      enabled: true
      dhcp: true
    ipv6:
      enabled: false
EOF

    nmstatectl apply "$pf_config_file"
    rm -f "$pf_config_file"

    # Verify nmstatectl actually configured the interface
    if ! nmstatectl show "$pf_name" --json | jq -e '.interfaces[0].ipv4.dhcp' &>/dev/null; then
        log "Error: nmstatectl apply succeeded but DHCP was not configured on $pf_name" >&2
        exit 1
    fi
    log "Successfully configured PF interface: $pf_name"
}

# --- Main Execution ---

wait_for "br-dpu bridge" check_bridge

PF_MTU=$(get_bridge_mtu)
if [ -z "$PF_MTU" ]; then
    log "Error: Could not get MTU from br-dpu bridge" >&2
    exit 1
fi
log "br-dpu bridge found with MTU: $PF_MTU"

wait_for "NFD DPU features file" check_nfd_file
log "NFD DPU features file found."

wait_for "PF interfaces in NFD features" check_pf_interfaces
read -ra PF_INTERFACES <<< "$(find_pf_interfaces)"
log "Found PF interfaces: ${PF_INTERFACES[*]}"

for pf in "${PF_INTERFACES[@]}"; do
    configure_pf_interface "$pf" "$PF_MTU"
done

log "PF configuration complete."
