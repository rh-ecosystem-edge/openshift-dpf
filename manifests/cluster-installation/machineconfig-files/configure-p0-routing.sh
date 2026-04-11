#!/bin/bash
set -e

# Long-running service that ensures routing table 100 stays configured for
# OVN-K traffic via br-dpu. Continuously monitors and re-applies rules/routes
# in case they are removed (e.g. after NMState reconfiguration).

CHECK_INTERVAL=2
RECONCILE_INTERVAL=60
PRIMARY_IP_FILE="/run/nodeip-configuration/primary-ip"

echo "Waiting for primary IP file to determine IP version..."

while [ ! -f "$PRIMARY_IP_FILE" ] || [ ! -s "$PRIMARY_IP_FILE" ]; do
    sleep $CHECK_INTERVAL
done

br_dpu_ip=$(tr -d '[:space:]' < "$PRIMARY_IP_FILE")
echo "Using br-dpu IP from $PRIMARY_IP_FILE: $br_dpu_ip"

if [[ "$br_dpu_ip" =~ : ]]; then
    IP_VERSION="6"
    IP_FLAG="-6"
    PREFIX_LEN="128"
    LINK_LOCAL_PATTERN="^fe80:"
    echo "Detected IPv6 configuration"
else
    IP_VERSION="4"
    IP_FLAG="-4"
    PREFIX_LEN="32"
    LINK_LOCAL_PATTERN="^169[.]254"
    echo "Detected IPv4 configuration"
fi

ensure_rule() {
    if ip $IP_FLAG -j rule list | jq -e --arg src "$br_dpu_ip" '.[] | select(.src == $src and .table == "100")' > /dev/null 2>&1; then
        return 0
    fi
    echo "Adding rule: from $br_dpu_ip/$PREFIX_LEN lookup 100"
    ip $IP_FLAG rule add from $br_dpu_ip/$PREFIX_LEN lookup 100
}

ensure_route() {
    local dst="$1"; shift
    if ip $IP_FLAG -j route show table 100 | jq -e --arg dst "$dst" '.[] | select(.dst == $dst)' > /dev/null 2>&1; then
        return 0
    fi
    echo "Adding route: $dst $*  table 100"
    ip $IP_FLAG route add $dst "$@" table 100
}

configure_routing() {
    local ovnk_iface="$1"
    local ovnk_ip="$2"

    local br_dpu_network
    br_dpu_network=$(ip $IP_FLAG -j route show dev br-dpu | jq -r '.[] | select(.protocol == "kernel") | .dst' | head -n1)
    if [ -z "$br_dpu_network" ]; then
        echo "Warning: Could not find br-dpu network, will retry"
        return 1
    fi

    local br_dpu_gateway
    br_dpu_gateway=$(ip $IP_FLAG -j route | jq -r '.[] | select(.dst == "default" and .dev == "br-dpu") | .gateway' | head -n1)
    if [ -z "$br_dpu_gateway" ]; then
        echo "Warning: Could not find gateway for br-dpu, will retry"
        return 1
    fi

    local ovnk_subnet
    ovnk_subnet=$(ip $IP_FLAG -j route | jq --arg dev "$ovnk_iface" --arg pattern "$LINK_LOCAL_PATTERN" -r '
      .[] | select(
        .dev == $dev
        and .dst != null
        and .dst != "default"
        and (.dst | test($pattern) | not)
        and .gateway == null
      ) | .dst' | head -n1)
    if [ -z "$ovnk_subnet" ]; then
        echo "Warning: Could not find subnet for $ovnk_iface, will retry"
        return 1
    fi

    local br_dpu_metric
    br_dpu_metric=$(ip $IP_FLAG -j route show dev br-dpu | jq -r '.[] | select(.protocol == "kernel") | .metric // 425' | head -n1)

    ensure_rule
    ensure_route "$ovnk_subnet" via "$br_dpu_gateway"
    ensure_route "$br_dpu_network" dev br-dpu proto kernel scope link src "$br_dpu_ip" metric "$br_dpu_metric"
    return 0
}

echo "Waiting for OVN-K interface (with link-local address) to get an IP address..."

configured=false
while true; do
    ovnk_ifaces=$(ip -j addr show | jq --arg pattern "$LINK_LOCAL_PATTERN" -r '.[] | select(.addr_info[]? | .local | test($pattern)) | .ifname' | sort -u)

    for ovnk_iface in $ovnk_ifaces; do
        ovnk_ip=$(ip $IP_FLAG -j addr show "$ovnk_iface" | jq --arg pattern "$LINK_LOCAL_PATTERN" -r '.[] | .addr_info[]? | select(.local | test($pattern) | not) | .local' | head -n1)

        if [ -n "$ovnk_ip" ]; then
            if [ "$configured" = "false" ]; then
                echo "Found OVN-K interface: $ovnk_iface with IPv${IP_VERSION}: $ovnk_ip"
            fi
            if configure_routing "$ovnk_iface" "$ovnk_ip"; then
                if [ "$configured" = "false" ]; then
                    echo "Routing configuration completed, entering reconcile loop"
                    configured=true
                fi
            fi
            break
        fi
    done

    if [ "$configured" = "true" ]; then
        sleep $RECONCILE_INTERVAL
    else
        sleep $CHECK_INTERVAL
    fi
done
