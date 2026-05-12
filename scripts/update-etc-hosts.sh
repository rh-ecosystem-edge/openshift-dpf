#!/bin/bash

# Constants
HOSTS_FILE="/etc/hosts"
PING_TIMEOUT=2
PING_COUNT=1

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# Print usage information
print_usage() {
    echo "Usage: $0 <ip_address> <fqdn> [vm_prefix]"
    echo "Example: $0 192.168.1.100 myserver.example.com"
    echo "Example with VM prefix: $0 192.168.1.100 myserver.example.com myvm"
}

# Check if script is run with sudo/root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run with sudo privileges"
        exit 1
    fi
}

# Check if an IP is reachable
check_ip_reachable() {
    local ip=$1
    ping -c $PING_COUNT -W $PING_TIMEOUT "$ip" >/dev/null 2>&1
    return $?
}

# Get list of VMs matching prefix
get_matching_vms() {
    local vm_prefix=$1
    virsh list --all | grep "$vm_prefix" | awk '{print $2}'
}

# Get IP address for a specific VM
# Get IP address for a specific VM
get_vm_ip() {
    local vm_name=$1
    local vm_mac
    local vm_ip

    # Try to get the IP using virsh domifaddr
    vm_ip=$(virsh domifaddr "$vm_name" 2>/dev/null | grep -v "^$" | tail -n +3 | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)

    if [ -n "$vm_ip" ]; then
        echo "$vm_ip"
        return 0
    fi

    # Fallback: Get the MAC address of the VM
    vm_mac=$(virsh domiflist "$vm_name" 2>/dev/null | tail -n +3 | awk '{print $5}' | head -n 1)

    if [ -z "$vm_mac" ]; then
        echo "Error: Could not retrieve MAC address for VM: $vm_name" >&2
        return 1
    fi

    # Use arp or ip neigh to find the IP address based on the MAC address
    vm_ip=$(arp -an | grep "$vm_mac" | awk '{print $2}' | tr -d '()')
    if [ -z "$vm_ip" ]; then
        vm_ip=$(ip neigh | grep "$vm_mac" | awk '{print $1}')
    fi

    if [ -n "$vm_ip" ]; then
        echo "$vm_ip"
        return 0
    else
        echo "Error: Could not find IP address for VM: $vm_name" >&2
        return 1
    fi
}

# Find IP address for any VM matching prefix
find_vm_ip() {
    local vm_prefix=$1
    local vm_ip=""

    echo "Looking for VMs matching prefix: $vm_prefix" >&2
    local vm_list=$(get_matching_vms "$vm_prefix")

    if [ -z "$vm_list" ]; then
        echo "No VMs found matching prefix: $vm_prefix" >&2
        return 1
    fi

    echo "Found VMs:" >&2
    echo "$vm_list" >&2

    for vm in $vm_list; do
        echo "Checking IP for VM: $vm" >&2
        vm_ip=$(get_vm_ip "$vm")
        if [ -n "$vm_ip" ]; then
            echo "Found IP: $vm_ip for VM: $vm" >&2
            echo "$vm_ip"
            return 0
        fi
    done

    echo "No IP addresses found for matching VMs" >&2
    return 1
}

# Update hosts file entry
update_hosts_file() {
    local ip=$1
    local fqdn=$2
    local temp_file=$(mktemp)
    local updated=0

    # Read hosts file line by line and update/add entry
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ ^[^#]*[[:space:]]+"$fqdn"([[:space:]]|$) ]]; then
            printf "%s\t%s\n" "$ip" "$fqdn" >> "$temp_file"
            updated=1
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$HOSTS_FILE"

    # If FQDN wasn't found, append new entry
    if [ $updated -eq 0 ]; then
        printf "%s\t%s\n" "$ip" "$fqdn" >> "$temp_file"
    fi

    # Backup original hosts file (requires sudo)
    sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"

    # Replace original hosts file (requires sudo)
    sudo cp "$temp_file" "$HOSTS_FILE"
    rm "$temp_file"

    echo "Updated $HOSTS_FILE (Backup created at ${HOSTS_FILE}.bak)"
    echo "New entry:"
    grep -E "^[^#]*[[:space:]]$fqdn([[:space:]]|$)" "$HOSTS_FILE" || true
}

# Main function
update_etc_hosts() {
    if [ "${SKIP_ETC_HOSTS}" = "true" ]; then
        echo "INFO: Skipping /etc/hosts update (SKIP_ETC_HOSTS=true)"
        return 0
    fi

    local fqdn=${HOST_CLUSTER_API}
    local vm_prefix="${VM_PREFIX}"
    local final_ip=""
    
    check_root
    
    # If VM_COUNT > 1 (multi-node), use API_VIP
    if [ "$VM_COUNT" -gt 1 ]; then
        echo "INFO: Multi-node cluster detected (VM_COUNT=${VM_COUNT}), using API_VIP: ${API_VIP}"
        final_ip=${API_VIP}
    else
        # Single-node cluster: find VM IP
        echo "INFO: Single-node cluster detected (VM_COUNT=${VM_COUNT}), finding VM IP for prefix: ${vm_prefix}"
        
        if [ -z "$vm_prefix" ]; then
            echo "Error: VM_PREFIX not set for single-node cluster"
            return 1
        fi
        
        local vm_ip=$(find_vm_ip "$vm_prefix")
        if [ -n "$vm_ip" ]; then
            echo "Found VM IP: $vm_ip"
            final_ip=$vm_ip
        else
            echo "Error: Could not find VM IP for prefix $vm_prefix"
            return 1
        fi
    fi

    update_hosts_file "$final_ip" "$fqdn"
}

# If script is executed directly (not sourced), run the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    update_etc_hosts "$@"
fi
