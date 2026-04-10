#!/bin/bash
# vm.sh - Virtual Machine Management

# Exit on error
set -e

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"

# Configuration
# Most VM configuration variables are defined in env.sh:
# VM_PREFIX, VM_COUNT, API_VIP, BRIDGE_NAME, DISK_PATH, RAM, VCPUS, DISK_SIZE1, DISK_SIZE2

# Get the default physical NIC (not defined in env.sh)
PHYSICAL_NIC=${PHYSICAL_NIC:-$(ip route | awk '/default/ {print $5; exit}')}

# ISO path derived from env.sh variables
ISO_PATH="${ISO_FOLDER}/${CLUSTER_NAME}.iso"

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------

generate_mac_with_custom_prefix() {
    local vm_index="$1"
    local custom_prefix="$2"
    if [[ ! "$custom_prefix" =~ ^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$ ]]; then
        log "ERROR" "Invalid MAC_PREFIX format: $custom_prefix. Must be 4 hex digits with colon (e.g., 'C0:00', 'A1:B2')"
        exit 1
    fi
    printf '52:54:00:%s:%02x' "$custom_prefix" "$vm_index"
}

# Generate MAC for a VM, using MAC_PREFIX if set, otherwise machine-id.
# Args: vm_name mac_index
_resolve_mac() {
    local vm_name="$1" mac_index="$2"
    if [ -n "$MAC_PREFIX" ]; then
        generate_mac_with_custom_prefix "$mac_index" "$MAC_PREFIX"
    else
        generate_mac_from_machine_id "$vm_name"
    fi
}

_delete_vms_by_prefix() {
    local prefix="$1"
    if [ -z "${prefix}" ]; then
        log "WARN" "No VM prefix provided, skipping deletion"
        return 0
    fi
    log "INFO" "Deleting VMs matching prefix ${prefix}..."
    local vms
    vms=$(virsh list --all | awk '{print $2}' | grep "^${prefix}" || true)
    for vm in ${vms}; do
        virsh destroy "${vm}" 2>/dev/null || true
        virsh undefine "${vm}" --remove-all-storage 2>/dev/null || true
    done
    log "INFO" "VMs matching prefix ${prefix} deleted"
}

# Create a single VM via virt-install (backgrounded).
# Args: vm_name ram vcpus disk1 disk2 network_arg
_create_vm() {
    local vm_name="$1" ram="$2" vcpus="$3" disk1="$4" disk2="$5" network_arg="$6"
    log "INFO" "Starting VM creation for $vm_name..."
    nohup virt-install --name "$vm_name" --memory "$ram" \
            --vcpus "$vcpus" \
            --os-variant=rhel9.4 \
            --disk pool=default,size="${disk1}" \
            --disk pool=default,size="${disk2}" \
            --network "${network_arg}" \
            --graphics=vnc \
            --events on_reboot=restart \
            --cdrom "$ISO_PATH" \
            --cpu host-passthrough \
            --noautoconsole \
            --wait=-1 &
}

_wait_for_vms_running() {
    local count="$1" prefix="$2"
    local max_retries=24 interval=5
    for i in $(seq 1 "$count"); do
        local vm_name="${prefix}${i}"
        local retries=0
        until [[ "$(virsh domstate "$vm_name" 2>/dev/null || true)" == "running" ]]; do
            if [[ $retries -ge $max_retries ]]; then
                log "ERROR" "VM $vm_name did not reach running state within 2 minutes"
                exit 1
            fi
            log "INFO" "Waiting for VM $vm_name to start... (Attempt: $((retries + 1))/$max_retries)"
            sleep $interval
            ((retries+=1))
        done
        log "INFO" "VM $vm_name is running"
    done
}

# -----------------------------------------------------------------------------
# VM Management Functions
# -----------------------------------------------------------------------------
# * Create VMs with prefix $VM_PREFIX.
# *
# * This function creates $VM_COUNT number of VMs with the given prefix.
# * The VMs are created with the given memory, number of virtual CPUs,
# * and disk sizes. The VMs are also configured with a direct network
# * connection to the given physical NIC and a VNC graphics device.
# * The function waits for all VMs to be running using a retry mechanism
# * and prints a success message upon completion.

function create_vms() {
    # First check if cluster is already installed
    if check_cluster_installed; then
        log "INFO" "Skipping VM creation as cluster is already installed"
        return 0
    fi

    log "Creating VMs with prefix $VM_PREFIX..."

    if [ "$SKIP_BRIDGE_CONFIG" != "true" ]; then
        # Ensure the bridge is created before creating VMs
        echo "Creating bridge with force mode..."
        "$(dirname "${BASH_SOURCE[0]}")/vm-bridge-ops.sh" --force
    else
        echo "Skipping bridge creation as SKIP_BRIDGE_CONFIG is set to true."
    fi

    if [ "${VM_STATIC_IP}" = "true" ]; then
        # Static IP mode: parse YAML and create VMs based on file content
        if [ ! -f "$STATIC_NET_FILE" ]; then
            log "ERROR" "VM_STATIC_IP=true but static network file not found: $STATIC_NET_FILE"
            exit 1
        fi
        log "INFO" "Found static_net.yaml. Creating VMs based on file content."
        # parse the YAML into a JSON string
        VMS_CONFIG=$(python3 -c 'import yaml, json; print(json.dumps(yaml.safe_load(open("'"$STATIC_NET_FILE"'"))["static_network_config"]))')

        i=1
        for interface_config in $(echo "$VMS_CONFIG" | jq -c '.[] | .interfaces[]'); do
           VM_MAC=$(echo "$interface_config" | jq -r '.["mac-address"]')
           VM_NAME="${VM_PREFIX}${i}"
           network_full_arg="bridge=${BRIDGE_NAME},model=virtio,mac=${VM_MAC}"

           _create_vm "$VM_NAME" "$RAM" "$VCPUS" "$DISK_SIZE1" "$DISK_SIZE2" "$network_full_arg"
           i=$((i+1))
        done
    else
      # DHCP mode: VM Creation Loop
      for i in $(seq 1 "$VM_COUNT"); do
        VM_NAME="${VM_PREFIX}${i}"
        UNIQUE_MAC=$(_resolve_mac "$VM_NAME" "$i")
        log "INFO" "Creating VM: $VM_NAME with MAC: $UNIQUE_MAC"
        network_full_arg="bridge=${BRIDGE_NAME},model=virtio,mac=${UNIQUE_MAC}"

        _create_vm "$VM_NAME" "$RAM" "$VCPUS" "$DISK_SIZE1" "$DISK_SIZE2" "$network_full_arg"
      done
    fi

    _wait_for_vms_running "$VM_COUNT" "$VM_PREFIX"
    log "VM creation completed successfully!"
}

function delete_vms() {
    if [ -n "${VM_WORKER_PREFIX}" ]; then
        _delete_vms_by_prefix "${VM_WORKER_PREFIX}"
    fi
    _delete_vms_by_prefix "${VM_PREFIX}"
}

# -----------------------------------------------------------------------------
# Worker VM functions (day2 flow via Assisted Installer)
# -----------------------------------------------------------------------------

function create_worker_vms() {
    local worker_count="${VM_WORKER_COUNT:-0}"
    if [ "${worker_count}" -eq 0 ]; then
        log "INFO" "VM_WORKER_COUNT=0, skipping worker VM creation"
        return 0
    fi

    log "INFO" "Creating ${worker_count} worker VM(s) with prefix ${VM_WORKER_PREFIX}..."

    if [ "$SKIP_BRIDGE_CONFIG" != "true" ]; then
        if ! ip link show "${BRIDGE_NAME}" &>/dev/null; then
            log "INFO" "Bridge ${BRIDGE_NAME} not found, creating..."
            "$(dirname "${BASH_SOURCE[0]}")/vm-bridge-ops.sh" --force
        fi
    fi

    local created=0
    for i in $(seq 1 "$worker_count"); do
        local vm_name="${VM_WORKER_PREFIX}${i}"

        if virsh dominfo "$vm_name" &>/dev/null; then
            log "INFO" "Worker VM $vm_name already exists, skipping"
            continue
        fi

        local mac_index=$(( VM_COUNT + i ))
        local mac=$(_resolve_mac "$vm_name" "$mac_index")
        log "INFO" "Creating worker VM: $vm_name with MAC: $mac"
        local network_full_arg="bridge=${BRIDGE_NAME},model=virtio,mac=${mac}"

        _create_vm "$vm_name" "$VM_WORKER_RAM" "$VM_WORKER_VCPUS" "$VM_WORKER_DISK_SIZE1" "$VM_WORKER_DISK_SIZE2" "$network_full_arg"
        ((created++)) || true
    done

    if [ "${created}" -eq 0 ]; then
        log "INFO" "All ${worker_count} worker VM(s) already exist, nothing to create"
        return 0
    fi

    _wait_for_vms_running "$worker_count" "$VM_WORKER_PREFIX"
    log "INFO" "Worker VM creation completed successfully!"
}

function delete_worker_vms() {
    if [ -n "${VM_WORKER_PREFIX}" ]; then
        _delete_vms_by_prefix "${VM_WORKER_PREFIX}"
    fi
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
function main() {
    local command=$1
    shift

    case "$command" in
        create)            create_vms ;;
        delete)            delete_vms ;;
        create-worker-vms) create_worker_vms ;;
        delete-worker-vms) delete_worker_vms ;;
        *)
            log "Unknown command: $command"
            log "Available commands: create, delete, create-worker-vms, delete-worker-vms"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        log "Usage: $0 <command> [arguments...]"
        log "Commands: create, delete, create-worker-vms, delete-worker-vms"
        exit 1
    fi
    main "$@"
fi
