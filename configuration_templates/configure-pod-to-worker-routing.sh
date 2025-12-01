#!/bin/bash

# Script to wait for OVN-K interface (identified by link-local) and configure routing table 100

CHECK_INTERVAL=2  # Check every 2 seconds
PRIMARY_IP_FILE="/run/nodeip-configuration/primary-ip"

echo "Waiting for primary IP file to determine IP version..."

# Wait for primary-ip file and determine IP version first
while [ ! -f "$PRIMARY_IP_FILE" ] || [ ! -s "$PRIMARY_IP_FILE" ]; do
    sleep $CHECK_INTERVAL
done

br_dpu_ip=$(cat "$PRIMARY_IP_FILE" | tr -d '[:space:]')
echo "Using br-dpu IP from $PRIMARY_IP_FILE: $br_dpu_ip"

# Detect IP version based on br-dpu IP and set all variables accordingly
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

echo "Waiting for OVN-K interface (with link-local address) to get an IP address..."

while true; do
    # Find all interfaces with link-local addresses using JSON output
    ovnk_ifaces=$(ip -j addr show | jq --arg pattern "$LINK_LOCAL_PATTERN" -r '.[] | select(.addr_info[]? | .local | test($pattern)) | .ifname' | sort -u)
    
    for ovnk_iface in $ovnk_ifaces; do
        # Get non-link-local IP address for the detected IP version
        ovnk_ip=$(ip $IP_FLAG -j addr show "$ovnk_iface" | jq --arg pattern "$LINK_LOCAL_PATTERN" -r '.[] | .addr_info[]? | select(.local | test($pattern) | not) | .local' | head -n1)
        
        if [ -n "$ovnk_ip" ]; then
            echo "Found OVN-K interface: $ovnk_iface with IPv${IP_VERSION}: $ovnk_ip"
            
            # Get br-dpu network from routing table using JSON
            br_dpu_network=$(ip $IP_FLAG -j route show dev br-dpu | jq -r '.[] | select(.protocol == "kernel") | .dst' | head -n1)
            
            if [ -z "$br_dpu_network" ]; then
                echo "Error: Could not find br-dpu network"
                exit 1
            fi
            
            echo "br-dpu network: $br_dpu_network"
            
            # Get br-dpu gateway from default route
            br_dpu_gateway=$(ip $IP_FLAG -j route | jq -r '.[] | select(.dst == "default" and .dev == "br-dpu") | .gateway' | head -n1)
            
            if [ -z "$br_dpu_gateway" ]; then
                echo "Error: Could not find gateway for br-dpu"
                exit 1
            fi
            
            echo "br-dpu gateway: $br_dpu_gateway"
            
            # Get OVN-K subnet from DHCP route
            ovnk_subnet=$(ip $IP_FLAG -j route | jq -r ".[] | select(.dev == \"$ovnk_iface\" and .protocol == \"dhcp\" and .dst != \"default\") | .dst" | head -n1)
            
            if [ -z "$ovnk_subnet" ]; then
                echo "Error: Could not find subnet for $ovnk_iface"
                exit 1
            fi
            
            echo "OVN-K subnet: $ovnk_subnet"
            
            # Get metric from br-dpu (default to 425 if not found)
            br_dpu_metric=$(ip $IP_FLAG -j route show dev br-dpu | jq -r '.[] | select(.protocol == "kernel") | .metric // 425' | head -n1)
            
            echo ""
            echo "Creating routing rules in table 100..."
            
            # 1. Add policy routing rule
            echo "Adding rule: from $br_dpu_ip/$PREFIX_LEN lookup 100"
            # Check if rule already exists using JSON
            if ip $IP_FLAG -j rule list | jq -e --arg src "$br_dpu_ip" '.[] | select(.src == $src and .table == "100")' > /dev/null 2>&1; then
                echo "Rule already exists"
            else
                ip $IP_FLAG rule add from $br_dpu_ip/$PREFIX_LEN lookup 100 2>/dev/null && echo "Rule added successfully" || echo "Failed to add rule (may already exist)"
            fi
            
            # 2. Add OVN-K route via gateway
            echo "Adding route: $ovnk_subnet via $br_dpu_gateway table 100"
            # Check if route already exists using JSON
            if ip $IP_FLAG -j route show table 100 | jq -e --arg dst "$ovnk_subnet" '.[] | select(.dst == $dst)' > /dev/null 2>&1; then
                echo "Route already exists"
            else
                ip $IP_FLAG route add $ovnk_subnet via $br_dpu_gateway table 100 2>/dev/null && echo "Route added successfully" || echo "Failed to add route (may already exist)"
            fi
            
            # 3. Add br-dpu subnet route
            echo "Adding route: $br_dpu_network dev br-dpu proto kernel scope link src $br_dpu_ip metric $br_dpu_metric table 100"
            # Check if route already exists using JSON
            if ip $IP_FLAG -j route show table 100 | jq -e --arg dst "$br_dpu_network" '.[] | select(.dst == $dst and .dev == "br-dpu")' > /dev/null 2>&1; then
                echo "Route already exists"
            else
                ip $IP_FLAG route add $br_dpu_network dev br-dpu proto kernel scope link src $br_dpu_ip metric $br_dpu_metric table 100 2>/dev/null && echo "Route added successfully" || echo "Failed to add route (may already exist)"
            fi
            
            echo ""
            echo "Routing configuration completed!"
            exit 0
        fi
    done
    
    sleep $CHECK_INTERVAL
done
