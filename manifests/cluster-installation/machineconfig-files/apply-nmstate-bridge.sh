#!/bin/bash
set -e

BRIDGE_NAME="br-dpu"
IP_HINT_FILE="/run/nodeip-configuration/primary-ip"
TARGET_MTU="$1"

set_bridge_rp_filter_loose() {
    local bridge="$1"
    echo "INFO: Setting rp_filter=2 (loose mode) on $bridge"
    sysctl -w "net.ipv4.conf.${bridge}.rp_filter=2"
}

validate_bridge_exists() {
    if ip link show "$BRIDGE_NAME" &> /dev/null; then
        set_bridge_rp_filter_loose "$BRIDGE_NAME"
        echo "INFO: Bridge '$BRIDGE_NAME' already exists. Configuration assumed complete."
        exit 0
    fi
}

get_nodeip_hint_interface() {
    local ip_hint_file="$1"

    if [[ ! -f "${ip_hint_file}" ]]; then
        echo "ERROR: IP hint file not found: $ip_hint_file" >&2
        return 1
    fi

    local ip_hint
    ip_hint=$(tr -d '[:space:]' < "${ip_hint_file}")

    if [[ -z "${ip_hint}" ]]; then
        echo "ERROR: IP hint file is empty: $ip_hint_file" >&2
        return 1
    fi

    echo "INFO: Node IP from hint file: $ip_hint" >&2

    local iface
    iface=$(ip -j addr | jq -r --arg ip "$ip_hint" --arg br "$BRIDGE_NAME" \
        'first(.[] | select(any(.addr_info[]; .local==$ip) and .ifname!=$br)) | .ifname')

    if [[ -z "${iface}" || "${iface}" == "null" ]]; then
        echo "ERROR: No interface found with IP $ip_hint" >&2
        return 1
    fi

    echo "${iface}"
}

apply_linux_bridge() {
    local iface="$1"
    local bridge="$BRIDGE_NAME"
    local mtu_arg="$2"

    if [ -z "$iface" ]; then
        echo "ERROR: No physical interface matches the Node IP in $IP_HINT_FILE." >&2
        exit 1
    fi

    echo "INFO: Target interface: $iface"
    echo "INFO: MTU policy: ${mtu_arg:+Set to $mtu_arg (user override)}${mtu_arg:-Inherit from physical interface}"

    local routes_json
    routes_json=$(nmstatectl show --json | jq -c --arg phys "$iface" \
        '[.routes.config // [] | .[] | select(.["next-hop-interface"] == $phys)]')

    echo "INFO: Generating NMState desired state..."
    nmstatectl show "$iface" --json | jq \
        --arg br "$bridge" \
        --arg phys "$iface" \
        --arg mtu_val "$mtu_arg" \
        --argjson phys_routes "$routes_json" \
    '
    .interfaces[0] as $p |
    (if $mtu_val != "" then {"mtu": ($mtu_val | tonumber)} else {} end) as $mtu_obj |
    {
        "interfaces": [
            ({
                "name": $br,
                "type": "linux-bridge",
                "state": "up",
                "mac-address": $p."mac-address",
                "ipv4": ($p.ipv4 | del(.forwarding)),
                "ipv6": ($p.ipv6 | del(.forwarding)),
                "bridge": {
                    "options": { "stp": { "enabled": false } },
                    "port": [{ "name": $phys }]
                }
            } + $mtu_obj),
            ({
                "name": $phys,
                "type": $p.type,
                "state": "up",
                "ipv4": { "enabled": false },
                "ipv6": { "enabled": false }
            } + $mtu_obj
              + if $p["link-aggregation"] then
                    { "link-aggregation": $p["link-aggregation"] }
                else {} end)
        ]
    }
    + if ($phys_routes | length) > 0 then
        { "routes": { "config": [$phys_routes[] | .["next-hop-interface"] = $br] } }
      else {} end
    ' > /tmp/br-dpu-config.yml

    echo "--- Generated NMState desired state ---"
    cat /tmp/br-dpu-config.yml
    echo "---------------------------------------"

    echo "INFO: Applying configuration via nmstatectl..."
    if nmstatectl apply /tmp/br-dpu-config.yml; then
        echo "SUCCESS: Bridge $bridge created successfully."
        ip addr show "$bridge"

        set_bridge_rp_filter_loose "$bridge"
    else
        echo "ERROR: Failed to apply NMState configuration." >&2
        rm -f /tmp/br-dpu-config.yml
        exit 1
    fi

    rm -f /tmp/br-dpu-config.yml
}

# --- Main ---
validate_bridge_exists
SELECTED_IFACE=$(get_nodeip_hint_interface "${IP_HINT_FILE}")
apply_linux_bridge "$SELECTED_IFACE" "$TARGET_MTU"
