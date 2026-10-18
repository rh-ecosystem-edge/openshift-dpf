#!/bin/bash
# cleanup.sh - Full deployment teardown (VMs, physical workers, Assisted Installer)

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/env.sh"

# Run full clean-all: delete libvirt VMs, remove Assisted Installer state and generated
# files, then power off physical workers. VM deletion failure still runs cluster cleanup,
# skips worker shutoff, and returns the VM deletion exit code. Worker shutoff failure is
# logged and does not fail the script.
clean_all() {
    local vm_status=0

    log "INFO" "Destroying libvirt VMs (worker + control-plane; release VIPs, stop BMO)..."
    "${SCRIPT_DIR}/vm.sh" delete || vm_status=$?

    log "INFO" "Deleting Assisted Installer cluster and generated files..."
    "${SCRIPT_DIR}/cluster.sh" clean-all

    if [[ "${vm_status}" -ne 0 ]]; then
        log "ERROR" "VM deletion failed; skipping physical worker shutoff"
        return "${vm_status}"
    fi

    log "INFO" "Powering off physical workers via ipmitool..."
    if ! "${SCRIPT_DIR}/worker.sh" shutoff-all-workers; then
        log "WARN" "Physical worker shutoff failed"
    fi

    log "INFO" "Full cleanup complete"
}

case "${1:-}" in
    clean-all)
        clean_all
        ;;
    *)
        echo "Usage: $0 clean-all"
        exit 1
        ;;
esac
