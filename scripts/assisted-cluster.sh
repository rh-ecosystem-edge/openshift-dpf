#!/bin/bash
# Optional NNO lifecycle and libvirt-side helpers. Never invoked by default DPF.
set -e
set -o pipefail

ASSISTED_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This new shell may inherit env.sh's marker without its functions.
unset ENV_SH_SOURCED
source "${ASSISTED_SCRIPT_DIR}/env.sh"
source "${ASSISTED_SCRIPT_DIR}/utils.sh"

assisted_cli() {
    python3 "${ASSISTED_SCRIPT_DIR}/assisted_install.py" "$@"
}

assisted_vm_macs() {
    local i name address xml addresses
    local -a pairs=()
    local domains
    domains=$(lvirsh list --all --name)
    for i in 1 2 3; do
        name="${VM_PREFIX}${i}"
        # Fail on connection errors instead of generating identities for a domain
        # we could not inspect. The wrappers handle remote libvirt transparently.
        if printf '%s\n' "$domains" | grep -Fxq "$name"; then
            xml=$(lvirsh dumpxml "$name")
            addresses=$(printf '%s' "$xml" | python3 -c 'import sys,xml.etree.ElementTree as E,json; print(json.dumps([e.attrib["address"] for e in E.fromstring(sys.stdin.read()).findall("./devices/interface/mac")]))')
            # Existing VM creation uses exactly one network interface.
            address=$(printf '%s' "$addresses" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert len(a)==1, "Ambiguous VM interfaces"; print(a[0])')
        elif [ -n "${MAC_PREFIX:-}" ]; then
            address="52:54:00:${MAC_PREFIX}:$(printf '%02x' "$i")"
        else
            address=$(generate_mac_from_machine_id "$name")
        fi
        pairs+=("$name" "$address")
    done
    python3 -c 'import json,sys; print(json.dumps(list(zip(sys.argv[1::2],sys.argv[2::2]))))' "${pairs[@]}"
}

assisted_download() {
    # Stream a protected curl config to the libvirt host. The signed URL is
    # neither a command argument nor logged, including in remote-libvirt mode.
    python3 -c '
import json,sys
from urllib.parse import urlsplit
url=sys.stdin.readline().strip()
assert urlsplit(url).scheme == "https" and "\n" not in url
print("url = " + json.dumps(url))
' | libvirt_host_cmd curl --disable --config - --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 1800 \
        --output "${ISO_FOLDER}/${CLUSTER_NAME}_infra-env.iso"
}

assisted_main() {
    is_day1_assisted || { log "ERROR" "This helper requires WORKER_PROVISIONING_MODE=day1-assisted"; return 1; }
    case "${1:-}" in
        vm-macs) assisted_vm_macs ;;
        network-input)
            source "${ASSISTED_SCRIPT_DIR}/cluster.sh"
            set_node_nmstate
            ;;
        download)
            libvirt_host_cmd mkdir -p "${ISO_FOLDER}"
            assisted_download
            ;;
        power-off)
            source "${ASSISTED_SCRIPT_DIR}/worker.sh"
            _shutoff_worker "$2"
            ;;
        *) assisted_cli "$@" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    assisted_main "$@"
fi
