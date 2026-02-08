#!/bin/bash
set -e

# --- Configuration ---
BRIDGE_NAME="br-dpu"
IP_HINT_FILE="/run/nodeip-configuration/primary-ip"

# --- Input Parameter Handling ---
TARGET_MTU="$1"

# --- Helper Functions ---

validate_bridge_exists() {
  if ip link show "$BRIDGE_NAME" &> /dev/null; then
    echo "INFO: Bridge '$BRIDGE_NAME' already exists. configuration assumed complete."
    # Optional: You could add logic here to verify the IP is actually on the bridge
    exit 0
  fi
}

get_ip_from_ip_hint_file() {
  local ip_hint_file="$1"
  if [[ ! -f "${ip_hint_file}" ]]; then return; fi
  cat "${ip_hint_file}"
}

get_nodeip_hint_interface() {
  local ip_hint_file="$1"
  local ip_hint
  local iface

  ip_hint=$(get_ip_from_ip_hint_file "${ip_hint_file}")
  
  if [[ -z "${ip_hint}" ]]; then
    echo "ERROR: IP Hint file is empty or missing at $ip_hint_file" >&2
    return
  fi

  # Find interface with matching IP, excluding the bridge itself
  iface=$(ip -j addr | jq -r "first(.[] | select(any(.addr_info[]; .local==\"${ip_hint}\") and .ifname!=\"$BRIDGE_NAME\")) | .ifname")
  
  if [[ -n "${iface}" ]]; then echo "${iface}"; fi
}

# --- Core Logic ---

apply_linux_bridge() {
    local iface="$1"
    local bridge="$BRIDGE_NAME"
    local mtu_arg="$2"

    if [ -z "$iface" ]; then
        # If we reached here, the bridge doesn't exist (checked earlier), 
        # but we also couldn't find the IP on any physical interface.
        echo "ERROR: Bridge does not exist, but no physical interface matches the Node IP in $IP_HINT_FILE."
        exit 1
    fi

    echo "INFO: Target Interface: $iface"
    
    if [ -n "$mtu_arg" ]; then
        echo "INFO: MTU Policy: Set to $mtu_arg (User Override)"
    else
        echo "INFO: MTU Policy: Inherit from physical interface (Default)"
    fi

    echo "INFO: Generating NMState configuration..."

    nmstatectl show "$iface" --json | jq --arg br "$bridge" --arg phys "$iface" --arg mtu_val "$mtu_arg" '
    .interfaces[0] as $p |
    (if $mtu_val != "" then ($mtu_val | tonumber) else $p.mtu end) as $effective_mtu |
    {
      "interfaces": [
        {
          "name": $br,
          "type": "linux-bridge",
          "state": "up",
          "mac-address": $p."mac-address",
          "mtu": $effective_mtu,
          "ipv4": $p.ipv4,
          "ipv6": $p.ipv6,
          "bridge": {
            "options": {
              "stp": { "enabled": false }
            },
            "port": [{ "name": $phys }]
          }
        },
        {
          "name": $phys,
          "type": $p.type,
          "state": "up",
          "mtu": $effective_mtu,
          "ipv4": { "enabled": false },
          "ipv6": { "enabled": false }
        }
      ]
    }' > /tmp/br-dpu-config.yml

    # Debug Output
    echo "--- Generated State ---"
    cat /tmp/br-dpu-config.yml
    echo "-----------------------"

    echo "INFO: Applying configuration via nmstatectl..."
    if nmstatectl apply /tmp/br-dpu-config.yml; then
        echo "SUCCESS: Bridge $bridge created successfully."
        ip addr show "$bridge"
    else
        echo "ERROR: Failed to apply configuration."
        exit 1
    fi
}

# --- Main Execution ---

# 1. Validation: Stop if bridge already exists
validate_bridge_exists

# 2. Discovery: Find the physical interface holding the IP
SELECTED_IFACE=$(get_nodeip_hint_interface "${IP_HINT_FILE}")

# 3. Execution: Apply the bridge
apply_linux_bridge "$SELECTED_IFACE" "$TARGET_MTU"