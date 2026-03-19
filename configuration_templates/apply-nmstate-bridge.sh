#!/bin/bash
set -e

BRIDGE_NAME="br-dpu"
IP_HINT_FILE="/run/nodeip-configuration/primary-ip"
TARGET_MTU="${1:-1500}"

validate_bridge_exists() {
  if ip link show "$BRIDGE_NAME" &> /dev/null; then
    echo "INFO: Bridge '$BRIDGE_NAME' already exists. Configuration assumed complete."
    exit 0
  fi
}

get_ip_from_ip_hint_file() {
  local ip_hint_file="$1"
  if [[ ! -f "${ip_hint_file}" ]]; then
    echo "ERROR: IP Hint file not found at $ip_hint_file" >&2
    exit 1
  fi
  cat "${ip_hint_file}"
}

validate_bridge_exists

IP_ADDR=$(get_ip_from_ip_hint_file "$IP_HINT_FILE")

echo "INFO: Discovering interface data for IP: $IP_ADDR..."

IFACE_DATA=$(ip -j addr show | jq -c ".[] | select(.ifname != \"$BRIDGE_NAME\") | select(any(.addr_info[]; .local==\"$IP_ADDR\"))")

if [[ -z "$IFACE_DATA" || "$IFACE_DATA" == "null" ]]; then
    echo "ERROR: No physical interface found with IP $IP_ADDR (excluding $BRIDGE_NAME)."
    exit 1
fi

IFACE_NAME=$(echo "$IFACE_DATA" | jq -r '.ifname')
MAC_ADDR=$(echo "$IFACE_DATA" | jq -r '.address')
PREFIX=$(echo "$IFACE_DATA" | jq -r ".addr_info[] | select(.local==\"$IP_ADDR\") | .prefixlen")

echo "INFO: Target Physical Interface: $IFACE_NAME"
echo "INFO: MAC: $MAC_ADDR | IP: $IP_ADDR/$PREFIX"

if echo "$IFACE_DATA" | grep -q '"dynamic":true'; then
    echo "INFO: Detected DHCP (dynamic) IP. Generating DHCP bridge config..."
    cat <<EOF > /tmp/br-dpu-config.yml
interfaces:
  - name: $BRIDGE_NAME
    type: linux-bridge
    state: up
    mac-address: $MAC_ADDR
    mtu: $TARGET_MTU
    ipv4:
      enabled: true
      dhcp: true
    bridge:
      options:
        stp: { enabled: false }
      port:
        - name: $IFACE_NAME
  - name: $IFACE_NAME
    type: ethernet
    state: up
    mtu: $TARGET_MTU
    ipv4: { enabled: false }
    ipv6: { enabled: false }
EOF
else
    echo "INFO: Detected STATIC IP. Generating Static bridge config..."
    GATEWAY=$(ip route show dev "$IFACE_NAME" | awk '/default via/ {print $3}')

    cat <<EOF > /tmp/br-dpu-config.yml
interfaces:
  - name: $BRIDGE_NAME
    type: linux-bridge
    state: up
    mac-address: $MAC_ADDR
    mtu: $TARGET_MTU
    ipv4:
      enabled: true
      dhcp: false
      address:
        - ip: $IP_ADDR
          prefix-length: $PREFIX
    bridge:
      options:
        stp: { enabled: false }
      port:
        - name: $IFACE_NAME
  - name: $IFACE_NAME
    type: ethernet
    state: up
    mtu: $TARGET_MTU
    ipv4: { enabled: false }
    ipv6: { enabled: false }
routes:
  config:
    - destination: 0.0.0.0/0
      next-hop-address: "$GATEWAY"
      next-hop-interface: "$BRIDGE_NAME"
EOF
fi

echo "INFO: Applying NMState configuration..."
if nmstatectl apply /tmp/br-dpu-config.yml; then
    echo "SUCCESS: Bridge $BRIDGE_NAME created and $IFACE_NAME attached."
    ip addr show "$BRIDGE_NAME"
    rm -f /tmp/br-dpu-config.yml
else
    echo "ERROR: Failed to apply configuration."
    exit 1
fi
