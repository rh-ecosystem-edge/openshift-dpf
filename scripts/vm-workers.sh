#!/usr/bin/env bash
# VM workers use an owned InfraEnv so failure cleanup never resets the base cluster.
set -euo pipefail

worker_exit() {
    if [ -n "${install_pid:-}" ]; then
        kill "$install_pid" 2>/dev/null || true
        wait "$install_pid" 2>/dev/null || true
    fi
    if [ -n "${worker_access_dir:-}" ]; then
        rm -rf -- "$worker_access_dir"
    fi
}

worker_access() {
    [ -n "${CLUSTER_PROFILE_DIR:-}" ] || return 0
    local profile="$CLUSTER_PROFILE_DIR" remote profile_cluster
    remote=$(cat "$profile/remote-host")
    profile_cluster=$(cat "$profile/cluster-name")
    if [[ ! "$remote" =~ ^[a-zA-Z0-9.-]+$ || "$profile_cluster" != "$CLUSTER_NAME" ]]; then
        echo "Invalid hypervisor host or cluster profile does not match CLUSTER_NAME" >&2
        return 1
    fi
    worker_access_dir=$(mktemp -d)
    chmod 700 "$worker_access_dir"
    mkdir -m 700 "$worker_access_dir/.aicli"
    export LIBVIRT_HOST="root@$remote" LIBVIRT_SSH_KEY="$worker_access_dir/key"
    base64 -d < "$profile/private-key" > "$LIBVIRT_SSH_KEY"
    printf '\n' >> "$LIBVIRT_SSH_KEY"
    chmod 600 "$LIBVIRT_SSH_KEY"
    local ssh_opts=(-i "$LIBVIRT_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    export AICLI_HOME="$worker_access_dir"
    # aicli's credential cache is isolated from the container user's home.
    if ! ssh "${ssh_opts[@]}" "$LIBVIRT_HOST" 'cat /root/.aicli/offlinetoken.txt' > "$AICLI_HOME/.aicli/offlinetoken.txt"; then
        if [ "$action" != delete ]; then
            echo "Cannot read the hypervisor Assisted Installer credential" >&2
            return 1
        fi
        echo "Assisted Installer credential unavailable; VM deletion will still be attempted" >&2
    fi
    chmod 600 "$AICLI_HOME/.aicli/offlinetoken.txt"
    export GENERATED_DIR="$repository_dir/manifests/generated"
    if [ "$action" != delete ]; then
        export KUBECONFIG="${SHARED_DIR:?SHARED_DIR is required in Prow}/kubeconfig"
        test -r "$KUBECONFIG"
        export OPENSHIFT_PULL_SECRET="$worker_access_dir/pull-secret.json" SSH_KEY="$worker_access_dir/cluster.pub"
        oc get secret pull-secret -n openshift-config -o 'go-template={{index .data ".dockerconfigjson"}}' | base64 -d > "$OPENSHIFT_PULL_SECRET"
        chmod 600 "$OPENSHIFT_PULL_SECRET"
    fi
}

aicli() {
    HOME="${AICLI_HOME:-$HOME}" command aicli "$@"
}

worker_names() {
    [[ "$VM_WORKER_PREFIX" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ "${#VM_WORKER_PREFIX}" -le 60 ] || {
        log ERROR "VM_WORKER_PREFIX must be a DNS hostname prefix of at most 60 characters"
        return 1
    }
    local digest
    digest=$(printf '%s' "$VM_WORKER_PREFIX" | sha256sum)
    worker_infraenv="${CLUSTER_NAME}-vmworker-${digest:0:12}"
    day2_cluster="${CLUSTER_NAME}-day2"
    worker_state="$GENERATED_DIR/vm-workers/$worker_infraenv"
    ISO_PATH="$ISO_FOLDER/$worker_infraenv.iso"
}

worker_cluster_id() {
    aicli -o json list clusters | jq -er --arg name "$day2_cluster" '[.[] | select(.name == $name)] | if length == 1 then .[0].id else empty end'
}

worker_infraenv_id() {
    aicli -o json list infraenvs | jq -er --arg name "$worker_infraenv" '[.[] | select(.name == $name)] | if length == 1 then .[0].id else empty end'
}

worker_create() {
    [[ "${VM_WORKER_COUNT:-0}" =~ ^[1-9][0-9]*$ ]] || { log ERROR "VM_WORKER_COUNT must be positive"; return 1; }
    local base cluster_id infraenv_id
    base=$(aicli -o json info cluster "$CLUSTER_NAME")
    local base_id
    base_id=$(jq -er 'select(.status == "installed" or .status == "adding-hosts") | .id // empty' <<< "$base")
    lvirsh list --all >/dev/null
    libvirt_host_cmd ip link show "$BRIDGE_NAME" >/dev/null
    if [ -n "${CLUSTER_PROFILE_DIR:-}" ]; then
        jq -er '.image_info.ssh_public_key | select(length > 0)' <<< "$base" > "$SSH_KEY"
    fi
    test -r "$OPENSHIFT_PULL_SECRET"
    test -r "$SSH_KEY"
    mkdir -p "$worker_state"
    local clusters
    clusters=$(aicli -o json list clusters)
    jq -e --arg name "$CLUSTER_NAME" '[.[] | select(.name == $name)] | length == 1' <<< "$clusters" >/dev/null
    if ! jq -e --arg name "$day2_cluster" 'any(.[]; .name == $name)' <<< "$clusters" >/dev/null; then
        aicli create cluster "$day2_cluster" -P infraenv=false
        cluster_id=$(worker_cluster_id)
        printf '%s\n' "$cluster_id" > "$worker_state/created-cluster"
    fi
    cluster_id=$(worker_cluster_id)
    aicli -o json info cluster "$cluster_id" | jq -e --arg base "$base_id" 'select(.status == "adding-hosts" and .openshift_cluster_id == $base)' >/dev/null
    local infraenvs
    infraenvs=$(aicli -o json list infraenvs)
    if jq -e --arg name "$worker_infraenv" 'any(.[]; .name == $name)' <<< "$infraenvs" >/dev/null; then
        infraenv_id=$(worker_infraenv_id)
        [ -f "$worker_state/infraenv" ] && [ "$(cat "$worker_state/infraenv")" = "$infraenv_id" ] || {
            log ERROR "InfraEnv $worker_infraenv exists without this checkout's ownership record"
            return 1
        }
    else
        aicli create infraenv "$worker_infraenv" -P cluster="$cluster_id" \
            -P openshift_version="$OPENSHIFT_VERSION" -P cpu_architecture="$(arch_for_aicli "$ARCH")" \
            -P pull_secret="$OPENSHIFT_PULL_SECRET" -P public_key="$SSH_KEY"
        infraenv_id=$(worker_infraenv_id)
        printf '%s\n' "$infraenv_id" > "$worker_state/infraenv"
    fi
    if [ "$NODES_MTU" != 1500 ]; then
        local nmstate="$worker_state/network.yaml"
        printf 'static_network_config:\n' > "$nmstate"
        _generate_nmstate_dhcp_entries "$nmstate" "$VM_WORKER_COUNT" "$VM_WORKER_PREFIX" "$VM_COUNT"
        aicli update infraenv "$worker_infraenv" --paramfile "$nmstate"
    fi
    get_iso "$worker_infraenv" day2 download
    # The bridge belongs to the deployed cluster and was checked above.
    SKIP_BRIDGE_CONFIG=true create_worker_vms
}

worker_name_hosts() {
    local hosts infraenv_id i mac host_id host status
    hosts=$(aicli -o json list hosts) || return 1
    infraenv_id=$(cat "$worker_state/infraenv")
    for i in $(seq 1 "$VM_WORKER_COUNT"); do
        mac=$(_resolve_mac "${VM_WORKER_PREFIX}${i}" "$((VM_COUNT + i))") || return 1
        host=$(jq -ec --arg ieid "$infraenv_id" --arg mac "$mac" '
            [.[] | select(.infra_env_id == $ieid) |
              select(any(((.inventory | try fromjson catch {}) | .interfaces // [])[]; .mac_address == $mac))] |
            if length == 1 then .[0] else empty end' <<< "$hosts") || return 1
        host_id=$(jq -r '.id' <<< "$host")
        status=$(jq -r '.status' <<< "$host")
        if [[ "$status" == installed || "$status" == added-to-existing-cluster ]]; then
            [ "$(jq -r '.requested_hostname' <<< "$host")" = "${VM_WORKER_PREFIX}${i}" ] || return 1
            continue
        fi
        aicli update host "$host_id" -P requested_hostname="${VM_WORKER_PREFIX}${i}" -P role=worker || return 1
    done
}

# Approve only kubelet CSRs with the exact subject and requester of these VMs.
worker_approve_csrs() {
    local requests pending csr signer username subject name i request_file="$worker_state/request.pem"
    requests=$(oc get csr -o json) || return 1
    pending=$(jq -c '.items[] | select((.status.conditions // [] | length) == 0 and (.status.certificate // "") == "")' <<< "$requests") || return 1
    while IFS= read -r csr; do
        [ -n "$csr" ] || continue
        signer=$(jq -r '.spec.signerName' <<< "$csr")
        username=$(jq -r '.spec.username' <<< "$csr")
        case "$signer" in
            kubernetes.io/kube-apiserver-client-kubelet|kubernetes.io/kubelet-serving) ;;
            *) continue ;;
        esac
        jq -r '.spec.request' <<< "$csr" | base64 -d > "$request_file" 2>/dev/null || continue
        openssl req -in "$request_file" -verify -noout >/dev/null 2>&1 || continue
        subject=$(openssl req -in "$request_file" -noout -subject -nameopt RFC2253) || return 1
        for i in $(seq 1 "$VM_WORKER_COUNT"); do
            name="${VM_WORKER_PREFIX}${i}"
            [ "$subject" = "subject=CN=system:node:$name,O=system:nodes" ] || continue
            case "$signer:$username" in
                kubernetes.io/kube-apiserver-client-kubelet:system:serviceaccount:openshift-machine-config-operator:node-bootstrapper|"kubernetes.io/kubelet-serving:system:node:$name")
                    oc adm certificate approve "$(jq -r '.metadata.name' <<< "$csr")" || return 1 ;;
            esac
        done
    done <<< "$pending"
    rm -f "$request_file"
}

worker_ready() {
    worker_approve_csrs || return 1
    local i
    for i in $(seq 1 "$VM_WORKER_COUNT"); do
        oc get node "${VM_WORKER_PREFIX}${i}" -o json | jq -e 'any(.status.conditions[]; .type == "Ready" and .status == "True")' >/dev/null || return 1
    done
}

worker_add() {
    worker_create
    log INFO "Waiting for this run's VM MAC addresses to register in $worker_infraenv"
    retry 30 30 worker_name_hosts
    local CLUSTER_NAME="$day2_cluster"
    if [ "${AUTO_APPROVE_WORKER_CSR:-false}" = true ]; then
        command -v openssl >/dev/null
        # Bootstrap approval can be required before AI reports installation complete.
        install_day2_hosts "$worker_infraenv" 45 &
        install_pid=$!
        while kill -0 "$install_pid" 2>/dev/null; do
            worker_approve_csrs
            sleep 5
        done
        local result=0
        wait "$install_pid" || result=$?
        unset install_pid
        [ "$result" = 0 ] || return "$result"
        retry 180 10 worker_ready
        log INFO "VM workers are Ready"
    else
        log INFO "Approve the VM workers' CSRs from another terminal while installation runs"
        install_day2_hosts "$worker_infraenv" 45
    fi
}

worker_delete() {
    # Stop VMs before removing Node/Assisted Installer records so they cannot rejoin.
    delete_worker_vms || return 1
    local infraenv_id current_id cluster_id remaining
    if [ -f "$worker_state/infraenv" ]; then
        infraenv_id=$(cat "$worker_state/infraenv")
        local infraenvs
        infraenvs=$(aicli -o json list infraenvs) || return 1
        current_id=$(jq -r --arg name "$worker_infraenv" '.[] | select(.name == $name) | .id' <<< "$infraenvs")
        if [ -n "$current_id" ]; then
            [ "$current_id" = "$infraenv_id" ] || { log ERROR "InfraEnv identity changed; refusing cleanup"; return 1; }
            aicli delete infraenv "$infraenv_id" --force -y || return 1
            aicli -o json list infraenvs | jq -e --arg id "$infraenv_id" 'all(.[]; .id != $id)' >/dev/null || return 1
        fi
        libvirt_host_cmd rm -f -- "$ISO_PATH" || return 1
        rm -f "$worker_state/infraenv"
    fi
    if [ -f "$worker_state/created-cluster" ]; then
        cluster_id=$(cat "$worker_state/created-cluster")
        local clusters
        clusters=$(aicli -o json list clusters) || return 1
        current_id=$(jq -r --arg name "$day2_cluster" '.[] | select(.name == $name) | .id' <<< "$clusters")
        if [ -n "$current_id" ]; then
            [ "$current_id" = "$cluster_id" ] || { log ERROR "Day2 cluster identity changed; refusing cleanup"; return 1; }
            remaining=$(aicli -o json list infraenvs | jq --arg id "$cluster_id" '[.[] | select(.cluster_id == $id)] | length') || return 1
            if [ "$remaining" != 0 ]; then
                log WARN "Preserving day2 record $day2_cluster: another InfraEnv uses it"
                return 0
            fi
            aicli delete cluster "$cluster_id" -y || return 1
            aicli -o json list clusters | jq -e --arg id "$cluster_id" 'all(.[]; .id != $id)' >/dev/null || return 1
        fi
    fi
    rm -rf -- "$worker_state"
}

worker_main() {
    local action="${1:?expected create, add, or delete}"
    trap worker_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local repository_dir
    repository_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    # Make has already exported .env; strip its quoting before profile checks.
    source "$repository_dir/scripts/env.sh"
    if [ "$action" != delete ] && [ "${VM_WORKER_COUNT:-0}" = 0 ]; then
        echo 'VM_WORKER_COUNT=0, skipping VM worker provisioning'
        return 0
    fi
    worker_access
    source "$repository_dir/scripts/vm.sh"
    worker_names
    case "$action" in
        create) worker_create ;;
        add) worker_add ;;
        delete) worker_delete ;;
        *) log ERROR "Unknown VM worker operation: $action"; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    worker_main "$@"
fi
