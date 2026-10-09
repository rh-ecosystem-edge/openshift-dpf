#!/bin/bash
# enable-kata.sh - Install Kata cold-plug from an RHCOS layer on DPU workers
#
# Kata and its CRI-O/cold-plug configuration come from the RHCOS layer.
# Existing OSC/KataConfig installations managing worker-dpu must be manually removed first.
# This flow targets only MCP worker-dpu and creates the configured RuntimeClass
# with handler kata-coldplug.
#
# Run after enable-ovn-injector with KATA_ENABLED=true so the kata NAD exists.
# make all runs this last when KATA_ENABLED=true.

set -e
set -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/post-install.sh"

KATA_MANIFESTS_DIR="${MANIFESTS_DIR}/kata"
GENERATED_KATA_DIR="${GENERATED_DIR}/kata"
KATA_DEFAULT_RHCOS_LAYER_IMAGE="quay.io/jensfr/rhcos-kata-dpu@sha256:83140f34a7a25d77f0d98bbcc512dddf7dfbe9961f7e05ee9c896519d1736719"
KATA_MC_APPLIED=false
KATA_COMPAT_MC_REQUIRED=false
worker_role="worker-dpu"

function kata_worker_role() {
    echo "worker-dpu"
}

function wait_for_api() {
    log [INFO] "Waiting for API to return..."
    until oc get nodes &>/dev/null; do
        sleep 15
    done
}

function assert_worker_dpu_pool() {
    local machine_count nodes
    if ! oc get mcp worker-dpu &>/dev/null; then
        log [ERROR] "MachineConfigPool worker-dpu not found. Deploy DPF / dpu-worker-config first."
        return 1
    fi
    machine_count=$(oc get mcp worker-dpu -o jsonpath='{.status.machineCount}' 2>/dev/null || true)
    if ! [[ "${machine_count}" =~ ^[1-9][0-9]*$ ]]; then
        log [ERROR] "MachineConfigPool worker-dpu has no nodes (machineCount=${machine_count:-0})."
        return 1
    fi
    nodes=$(oc get nodes -l node-role.kubernetes.io/worker-dpu -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${nodes}" ]; then
        log [ERROR] "No nodes carry node-role.kubernetes.io/worker-dpu."
        return 1
    fi
}

function assert_no_legacy_osc_state() {
    local kata_crd kata_configs_json dpu_nodes_json kata_targets kata_oc_nodes

    if ! dpu_nodes_json=$(oc get nodes -l node-role.kubernetes.io/worker-dpu -o json 2>/dev/null); then
        log [ERROR] "Could not read worker-dpu nodes while checking for legacy OSC state."
        return 1
    fi

    if ! kata_crd=$(oc get crd kataconfigs.kataconfiguration.openshift.io --ignore-not-found -o name 2>/dev/null); then
        log [ERROR] "Could not check for legacy KataConfig resources. Verify cluster API access and retry."
        return 1
    fi
    if [ -n "${kata_crd}" ]; then
        if ! kata_configs_json=$(oc get kataconfigs.kataconfiguration.openshift.io -o json 2>/dev/null); then
            log [ERROR] "Could not list legacy KataConfig resources. Verify cluster API access and retry."
            return 1
        fi
        if ! kata_targets=$(
            {
                printf '['
                printf '%s' "${dpu_nodes_json}"
                printf ','
                printf '%s' "${kata_configs_json}"
                printf ']'
            } | python3 -c '
import json, sys
nodes, configs = json.load(sys.stdin)

def matches(selector, labels):
    selector = selector or {}
    match_labels = selector.get("matchLabels", {}) or {}
    expressions = selector.get("matchExpressions", []) or []
    for key, value in match_labels.items():
        if labels.get(key) != value:
            return False
    for expression in expressions:
        key = expression.get("key")
        operator = expression.get("operator")
        values = expression.get("values", []) or []
        present = key in labels
        value = labels.get(key, "")
        if operator == "In":
            matched = present and value in values
        elif operator == "NotIn":
            matched = not present or value not in values
        elif operator == "Exists":
            matched = present
        elif operator == "DoesNotExist":
            matched = not present
        elif operator in ("Gt", "Lt"):
            if not present:
                matched = False
            else:
                try:
                    matched = int(value) > int(values[0]) if operator == "Gt" else int(value) < int(values[0])
                except (ValueError, IndexError):
                    matched = True
        else:
            # Unknown selector forms fail closed for nodes in the target pool.
            matched = True
        if not matched:
            return False
    return True

for config in configs.get("items", []):
    selector = config.get("spec", {}).get("kataConfigPoolSelector") or {}
    for node in nodes.get("items", []):
        if matches(selector, node.get("metadata", {}).get("labels", {})):
            config_name = config.get("metadata", {}).get("name", "<unnamed>")
            node_name = node.get("metadata", {}).get("name", "<unnamed>")
            print(f"{config_name} -> {node_name}")
'
        ); then
            log [ERROR] "Could not evaluate legacy KataConfig selectors. Verify Python 3 and cluster API data."
            return 1
        fi
        if [ -n "${kata_targets}" ]; then
            log [ERROR] "Legacy KataConfig selector(s) still match worker-dpu node(s):"
            echo "${kata_targets}"
            log [ERROR] "Stop Kata workloads, delete the matching KataConfig, and wait for its installer cleanup before retrying."
            return 1
        fi
    fi

    if ! kata_oc_nodes=$(oc get nodes -l node-role.kubernetes.io/worker-dpu,node-role.kubernetes.io/kata-oc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); then
        log [ERROR] "Could not check worker-dpu nodes for legacy kata-oc labels. Verify cluster API access and retry."
        return 1
    fi
    if [ -n "${kata_oc_nodes}" ]; then
        log [ERROR] "worker-dpu nodes still have node-role.kubernetes.io/kata-oc: ${kata_oc_nodes}"
        log [ERROR] "Complete legacy OSC cleanup and remove the stale role labels before retrying."
        return 1
    fi
}

function validate_layer_image() {
    local release arches arch
    case "${KATA_SKIP_RHCOS_LAYER:-false}" in
        true|TRUE|True|1|yes|YES)
            log [ERROR] "KATA_SKIP_RHCOS_LAYER is no longer supported; layer-only Kata requires KATA_RHCOS_LAYER_IMAGE. Remove the setting or set it to false."
            return 1
            ;;
    esac

    if ! [[ "${KATA_RHCOS_LAYER_IMAGE:-}" =~ @sha256:[a-f0-9]{64}$ ]]; then
        log [ERROR] "KATA_RHCOS_LAYER_IMAGE must be a digest-pinned image reference."
        return 1
    fi

    if ! release=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null) || [ -z "${release}" ]; then
        log [ERROR] "Could not read the cluster release version."
        return 1
    fi
    if [ "${KATA_RHCOS_LAYER_IMAGE}" = "${KATA_DEFAULT_RHCOS_LAYER_IMAGE}" ]; then
        if ! [[ "${release}" =~ ^4\.22([.]|$) ]]; then
            log [ERROR] "The default Kata layer is built for OpenShift 4.22; cluster release is ${release}. Set KATA_RHCOS_LAYER_IMAGE to a digest-pinned layer built for this cluster's RHCOS release."
            return 1
        fi
    else
        log [WARN] "Using custom Kata layer image; ensure it matches the worker-dpu RHCOS release and architecture (${release}, x86_64)."
    fi

    if ! arches=$(oc get nodes -l node-role.kubernetes.io/worker-dpu -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' 2>/dev/null); then
        log [ERROR] "Could not read worker-dpu node architectures."
        return 1
    fi
    if [ -z "${arches}" ]; then
        log [ERROR] "No worker-dpu node architecture data is available."
        return 1
    fi
    for arch in ${arches}; do
        if [ "${arch}" != "amd64" ]; then
            log [ERROR] "The Kata DPU layer supports x86_64 nodes; found worker-dpu architecture '${arch}'."
            return 1
        fi
    done
}

function cluster_has_kata_sriov_pool() {
    local pools
    pools=$(oc get nodesriovdevicepluginconfig "${SRIOV_DP_CONFIG_CR_NAME}" -n dpf-operator-system \
        -o jsonpath='{range .spec.devicePluginResources[*]}{.name}{"\n"}{end}' 2>/dev/null || true)
    grep -Fx "${KATA_SRIOV_DP_CONFIG_NAME}" <<< "${pools}" >/dev/null
}

function ensure_kata_sriov_pool() {
    if cluster_has_kata_sriov_pool; then
        log [INFO] "NodeSRIOVDevicePluginConfig already has kata pool ${KATA_SRIOV_DP_CONFIG_NAME}"
        return 0
    fi
    if ! [[ "${NUM_VFS}" =~ ^[1-9][0-9]*$ ]]; then
        log [ERROR] "NUM_VFS must be a positive integer"
        return 1
    fi
    log [INFO] "Kata VF pool missing from NodeSRIOVDevicePluginConfig; regenerating and applying"
    mkdir -p "${GENERATED_POST_INSTALL_DIR}"
    update_nodesriov_device_plugin_config
    apply_manifest "${GENERATED_POST_INSTALL_DIR}/nodesriovdevicepluginconfig.yaml" "true"
    log [INFO] "NodeSRIOVDevicePluginConfig applied"
}


function wait_for_mcp() {
    local pool=$1
    local expected_layer=${2:-}
    local expected_machineconfigs=${3:-}
    if [ -n "${expected_layer}" ]; then
        log [INFO] "Waiting for MachineConfigPool ${pool} to apply the expected layer (nodes may reboot)..."
    elif [ -n "${expected_machineconfigs}" ]; then
        log [INFO] "Waiting for MachineConfigPool ${pool} to render the required MachineConfigs..."
    else
        log [INFO] "Waiting for MachineConfigPool ${pool} to finish any existing rollout before node checks..."
    fi
    local attempts=0
    local max_attempts=90
    while [ $attempts -lt $max_attempts ]; do
        attempts=$((attempts + 1))

        if ! oc get nodes &>/dev/null; then
            log [INFO] "API unavailable (node rebooting)..."
            wait_for_api
            sleep 15
            continue
        fi

        local mcp_json mcp_state
        local ready total updated degraded spec_config status_config spec_sources cond_updated cond_updating cond_degraded
        local rendered_layer="" layer_ready=true sources_ready=true expected_source
        if ! mcp_json=$(oc get mcp "${pool}" -o json --request-timeout=10s 2>/dev/null); then
            log [INFO] "Could not read MCP ${pool}; retrying..."
            sleep 15
            continue
        fi
        if ! mcp_state=$(python3 -c '
import json, sys
mcp = json.load(sys.stdin)
status = mcp.get("status", {})
conditions = {condition.get("type"): condition.get("status", "-") for condition in status.get("conditions", [])}
configuration = status.get("configuration", {}).get("name", "-")
spec_configuration = mcp.get("spec", {}).get("configuration", {}).get("name", "-")
spec_sources = ",".join(source.get("name", "") for source in mcp.get("spec", {}).get("configuration", {}).get("source", []) if source.get("name"))
values = [
    status.get("readyMachineCount", "-"),
    status.get("machineCount", "-"),
    status.get("updatedMachineCount", "-"),
    status.get("degradedMachineCount", "-"),
    spec_configuration,
    configuration,
    spec_sources or "-",
    conditions.get("Updated", "-"),
    conditions.get("Updating", "-"),
    conditions.get("Degraded", "-"),
]
print("\t".join(str(value) if value not in (None, "") else "-" for value in values))
' <<< "${mcp_json}"); then
            log [ERROR] "Could not parse MCP ${pool} status."
            return 1
        fi
        IFS=$'\t' read -r ready total updated degraded spec_config status_config spec_sources cond_updated cond_updating cond_degraded <<< "${mcp_state}"
        [ "${ready}" = "-" ] && ready=""
        [ "${total}" = "-" ] && total=""
        [ "${updated}" = "-" ] && updated=""
        [ "${degraded}" = "-" ] && degraded="0"
        [ "${spec_config}" = "-" ] && spec_config=""
        [ "${status_config}" = "-" ] && status_config=""
        [ "${spec_sources}" = "-" ] && spec_sources=""
        [ "${cond_updated}" = "-" ] && cond_updated=""
        [ "${cond_updating}" = "-" ] && cond_updating=""
        [ "${cond_degraded}" = "-" ] && cond_degraded=""

        log [INFO] "MCP ${pool}: ready=${ready:-?}/${total:-?} updated=${updated:-?} spec=${spec_config:-?} status=${status_config:-?} Updated=${cond_updated:-?} Updating=${cond_updating:-?} Degraded=${cond_degraded:-?}/${degraded:-?}"

        if [ "${degraded:-0}" != "0" ] || [ "${cond_degraded}" = "True" ]; then
            log [ERROR] "MachineConfigPool ${pool} is degraded"
            oc get mcp "${pool}" -o yaml || true
            return 1
        fi

        if [ -n "${expected_layer}" ] && [ -n "${spec_config}" ]; then
            rendered_layer=$(oc get mc "${spec_config}" -o jsonpath='{.spec.osImageURL}' --request-timeout=10s 2>/dev/null || true)
            if [ "${rendered_layer}" != "${expected_layer}" ]; then
                layer_ready=false
            fi
        fi
        if [ -n "${expected_machineconfigs}" ]; then
            for expected_source in ${expected_machineconfigs//,/ }; do
                case ",${spec_sources}," in
                    *,"${expected_source}",*) ;;
                    *) sources_ready=false ;;
                esac
            done
        fi
        if [ "${layer_ready}" = "true" ] \
            && [ "${sources_ready}" = "true" ] \
            && [ "${spec_config}" = "${status_config}" ] \
            && [ -n "${spec_config}" ] \
            && [ "${cond_updated}" = "True" ] \
            && [ "${cond_updating}" = "False" ] \
            && [ "${cond_degraded}" = "False" ] \
            && [ -n "${total}" ] && [ "${total}" != "0" ] \
            && [ "${ready}" = "${total}" ] && [ "${updated}" = "${total}" ]; then
            if [ -n "${expected_layer}" ]; then
                log [INFO] "MachineConfigPool ${pool} has applied expected layer ${expected_layer} to all nodes"
            else
                log [INFO] "MachineConfigPool ${pool} is healthy and fully updated"
            fi
            return 0
        fi

        if [ -n "${expected_layer}" ] && [ -n "${spec_config}" ] && [ -n "${rendered_layer}" ] && [ "${rendered_layer}" != "${expected_layer}" ]; then
            log [INFO] "Rendered MachineConfig ${spec_config} has osImageURL '${rendered_layer}', waiting for '${expected_layer}'"
        fi
        if [ -n "${expected_machineconfigs}" ] && [ "${sources_ready}" != "true" ]; then
            log [INFO] "MCP ${pool} rendered sources do not include all required MachineConfigs '${expected_machineconfigs}' yet (sources: ${spec_sources:-none})"
        fi
        sleep 20
    done

    if [ -n "${expected_layer}" ]; then
        log [ERROR] "Timed out waiting for MachineConfigPool ${pool} to apply the expected layer after ${max_attempts} attempts"
    else
        log [ERROR] "Timed out waiting for MachineConfigPool ${pool} to become healthy after ${max_attempts} attempts"
    fi
    oc get mcp "${pool}" || true
    return 1
}

function verify_layer_on_nodes() {
    local nodes node result verify_fail=0 inspect_script
    nodes=$(oc get nodes -l node-role.kubernetes.io/worker-dpu -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${nodes}" ]; then
        log [ERROR] "No worker-dpu nodes found for layer verification."
        return 1
    fi

    inspect_script=$(cat <<'NODE_SCRIPT'
rpm_v=$(rpm -q kata-containers 2>/dev/null || echo MISSING)
initrd=$(readlink -f /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null)
kernel=$(readlink -f /var/cache/kata-containers/osbuilder-images/kata.kernel 2>/dev/null)
[ -f "$initrd" ] || initrd=""
[ -f "$kernel" ] || kernel=""
crio_config=/etc/crio/crio.conf.d/50-kata-coldplug
kata_config=/etc/kata-containers/config.d/50-kata-coldplug.toml
# Match the layer smoke test: verify that the RPM installed this drop-in.
crio=$(test -f "$crio_config" && echo ok || echo MISSING)
configd=$(test -f "$kata_config" && echo ok || echo MISSING)
vfio=$(grep -Eq '^[[:space:]]*vfio-pci[[:space:]]*$' /etc/modules-load.d/kata-vfio.conf 2>/dev/null && echo ok || echo MISSING)
coldplug=$(grep -Eq 'cold_plug_vfio[[:space:]]*=[[:space:]]*"?root-port"?' "$kata_config" 2>/dev/null && echo ok || echo MISSING)
mlx5=$(lsinitrd /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null | grep -c "mlx5_core\.ko" || true)
echo "rpm=$rpm_v"
echo "initrd=$initrd"
echo "kernel=$kernel"
echo "crio_handler=$crio"
echo "config_d=$configd"
echo "vfio_module=$vfio"
echo "coldplug_config=$coldplug"
echo "mlx5_count=$mlx5"
NODE_SCRIPT
)

    for node in ${nodes}; do
        log [INFO] "Verifying Kata layer on ${node}..."
        if ! result=$(oc debug "node/${node}" --quiet -- chroot /host bash -c "${inspect_script}" 2>&1); then
            log [ERROR] "Could not inspect Kata layer on ${node}."
            echo "${result}"
            verify_fail=1
            continue
        fi
        echo "${result}"
        if ! grep -q '^rpm=kata-containers-4\.1\.0-3\.' <<< "${result}" \
            || grep -q 'MISSING' <<< "${result}" \
            || grep -qE '^initrd=$|^kernel=$|^mlx5_count=0$' <<< "${result}"; then
            log [ERROR] "Kata layer verification failed on ${node}."
            verify_fail=1
        fi
    done

    if [ "${verify_fail}" -ne 0 ]; then
        return 1
    fi
    log [INFO] "Kata layer verified on all worker-dpu nodes"
}

function render_kata_manifest() {
    local src=$1
    local dest=$2
    shift 2
    update_file_multi_replace "${src}" "${dest}" "$@"
}

function ensure_one_machineconfig() {
    local name=$1
    local src=$2
    shift 2
    local dest="${GENERATED_KATA_DIR}/$(basename "${src}")"
    log [INFO] "Applying MachineConfig ${name} (role ${worker_role})"
    render_kata_manifest \
        "${src}" \
        "${dest}" \
        "<KATA_MC_ROLE>" "${worker_role}" \
        "$@"
    local out
    if ! out=$(oc apply -f "${dest}" 2>&1); then
        log [ERROR] "Failed to apply MachineConfig ${name}"
        echo "${out}"
        return 1
    fi
    log [INFO] "${out}"
    if echo "${out}" | grep -qE ' created$| configured$'; then
        KATA_MC_APPLIED=true
    fi
}

function remove_legacy_machineconfig() {
    local name=$1
    if oc get machineconfig "${name}" &>/dev/null; then
        log [INFO] "Removing obsolete Kata MachineConfig ${name}"
        oc delete machineconfig "${name}"
        KATA_MC_APPLIED=true
    fi
}

function ensure_machineconfigs() {
    remove_legacy_machineconfig 50-kata-coldplug-config

    ensure_one_machineconfig 99-kata-dpu-layered \
        "${KATA_MANIFESTS_DIR}/03-rhcos-layer.yaml" \
        "<KATA_RHCOS_LAYER_IMAGE>" "${KATA_RHCOS_LAYER_IMAGE}"
    ensure_one_machineconfig 99-iommu-enable \
        "${KATA_MANIFESTS_DIR}/03-iommu.yaml"
}

function ensure_crio_handler_compat_machineconfig() {
    local nodes node result needs_compat=false inspect_script
    nodes=$(oc get nodes -l "node-role.kubernetes.io/${worker_role}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${nodes}" ]; then
        log [ERROR] "No nodes with role ${worker_role} found while checking the CRI-O handler."
        return 1
    fi

    inspect_script=$(cat <<'NODE_SCRIPT'
if [ -f /etc/crio/crio.conf.d/50-kata-coldplug ]; then
    echo handler=active
elif [ -f /usr/etc/crio/crio.conf.d/50-kata-coldplug ]; then
    echo handler=vendor-only
else
    echo handler=missing
fi
NODE_SCRIPT
)

    for node in ${nodes}; do
        if ! result=$(oc debug "node/${node}" --quiet -- chroot /host bash -c "${inspect_script}" 2>&1); then
            log [ERROR] "Could not inspect the CRI-O handler on ${node}."
            echo "${result}"
            return 1
        fi
        if grep -Fxq "handler=active" <<< "${result}"; then
            continue
        elif grep -Fxq "handler=vendor-only" <<< "${result}"; then
            needs_compat=true
        elif grep -Fxq "handler=missing" <<< "${result}"; then
            log [ERROR] "CRI-O handler is missing from both /etc and /usr/etc on ${node}."
            return 1
        else
            log [ERROR] "Could not determine CRI-O handler state on ${node}."
            echo "${result}"
            return 1
        fi
    done

    if [ "${needs_compat}" = "true" ]; then
        log [WARN] "The RPM handler exists under /usr/etc but is absent from active /etc; applying a compatibility MachineConfig."
        KATA_COMPAT_MC_REQUIRED=true
        ensure_one_machineconfig 50-kata-coldplug-handler \
            "${KATA_MANIFESTS_DIR}/04-crio-handler-compat.yaml"
    fi
}

function wait_for_runtimeclass() {
    local name=$1
    local max_attempts=${2:-6}
    log [INFO] "Checking RuntimeClass ${name}..."
    local attempts=0
    while [ $attempts -lt $max_attempts ]; do
        if oc get runtimeclass "${name}" &>/dev/null; then
            log [INFO] "RuntimeClass ${name} exists"
            return 0
        fi
        attempts=$((attempts + 1))
        log [INFO] "RuntimeClass ${name} not found (attempt ${attempts}/${max_attempts})"
        sleep 10
    done
    return 1
}

function ensure_runtimeclass() {
    local name=$1
    log [INFO] "Applying RuntimeClass ${name} (nodeSelector ${worker_role})"
    render_kata_manifest \
        "${KATA_MANIFESTS_DIR}/05-runtimeclass.yaml" \
        "${GENERATED_KATA_DIR}/05-runtimeclass.yaml" \
        "<KATA_RUNTIME_CLASS>" "${name}" \
        "<WORKER_ROLE>" "${worker_role}"
    apply_manifest "${GENERATED_KATA_DIR}/05-runtimeclass.yaml" "true"
    wait_for_runtimeclass "${name}" 12
}

function render_kata_test_deployment() {
    mkdir -p "${GENERATED_KATA_DIR}"
    local role
    role=$(kata_worker_role)
    render_kata_manifest \
        "${KATA_MANIFESTS_DIR}/06-test-deployment.yaml" \
        "${GENERATED_KATA_DIR}/06-test-deployment.yaml" \
        "<KATA_RUNTIME_CLASS>" "${KATA_RUNTIME_CLASS}" \
        "<WORKER_ROLE>" "${role}" \
        "<KATA_TEST_REPLICAS>" "${KATA_TEST_REPLICAS}"
}

function deploy_kata_test() {
    get_kubeconfig
    render_kata_test_deployment

    # Drop the leftover standalone smoke-test Pod if present (same name as the Deployment).
    oc delete pod kata-dpu-test --ignore-not-found --wait=false >/dev/null 2>&1 || true

    apply_manifest "${GENERATED_KATA_DIR}/06-test-deployment.yaml" "true"

    if [ "${KATA_TEST_REPLICAS}" -eq 0 ]; then
        log [INFO] "KATA_TEST_REPLICAS=0: scaled kata-dpu-test to zero"
        return 0
    fi

    local timeout=$((KATA_TEST_REPLICAS * 180))
    log [INFO] "Waiting for deployment/kata-dpu-test (${KATA_TEST_REPLICAS} replicas, timeout ${timeout}s)..."
    oc wait --for=condition=Available deployment/kata-dpu-test --timeout="${timeout}s"
    oc get pods -l app=kata-dpu-test -o wide
    log [INFO] "Verify one replica: oc exec deploy/kata-dpu-test -- ping -c 3 8.8.8.8"
}

function check_kvm_on_workers() {
    local nodes node result
    nodes=$(oc get nodes -l "node-role.kubernetes.io/${worker_role}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${nodes}" ]; then
        log [ERROR] "No nodes with role ${worker_role} found; cannot verify /dev/kvm."
        return 1
    fi
    for node in ${nodes}; do
        log [INFO] "Checking /dev/kvm on ${node}..."
        if ! result=$(oc debug "node/${node}" --quiet -- chroot /host bash -c 'if [ -e /dev/kvm ]; then echo kvm=present; else echo kvm=missing; fi' 2>&1); then
            log [ERROR] "Could not inspect /dev/kvm on ${node}; oc debug failed, possibly because the node is not Ready."
            echo "${result}"
            return 1
        fi
        if grep -Fxq "kvm=missing" <<< "${result}"; then
            log [ERROR] "/dev/kvm missing on ${node} (VMX/SVM disabled in BIOS). Enable virtualization and cold-boot the host before enable-kata."
            return 1
        fi
        if ! grep -Fxq "kvm=present" <<< "${result}"; then
            log [ERROR] "Could not confirm /dev/kvm on ${node}; unexpected oc debug output:"
            echo "${result}"
            return 1
        fi
    done
}

function cleanup_stale_vfs() {
    get_kubeconfig
    worker_role=$(kata_worker_role)

    local kata_pods
    kata_pods=$(oc get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RC:.spec.runtimeClassName,PHASE:.status.phase --no-headers 2>/dev/null \
        | awk -v rc="${KATA_RUNTIME_CLASS}" '$3==rc && $4!="Succeeded" && $4!="Failed" {print $1"/"$2" "$4}')
    if [ -n "${kata_pods}" ] && [ "${FORCE:-false}" != "true" ]; then
        log [ERROR] "Kata pods are still present; rebinding would unplug VFs in use:"
        echo "${kata_pods}"
        log [ERROR] "Delete or scale them down first, then re-run. Override with FORCE=true."
        exit 1
    fi

    local nodes node
    nodes=$(oc get nodes -l "node-role.kubernetes.io/${worker_role}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${nodes}" ]; then
        log [ERROR] "No nodes with role ${worker_role} found"
        exit 1
    fi

    # Rebind leftover VFs on both PFs: vfio-pci, UNBOUND, or mlx5_core with
    # driver_override=vfio-pci. Idle mlx5_core + (null) override is left alone.
    for node in ${nodes}; do
        log [INFO] "Rebinding stale VFIO VFs on ${node}..."
        oc debug "node/${node}" --quiet -- chroot /host bash -c '
for pf in $(ls /sys/class/net | grep np); do
  for vf in /sys/class/net/$pf/device/virtfn*; do
    [ -e "$vf" ] || continue
    pci=$(basename $(readlink $vf))
    driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver 2>/dev/null) 2>/dev/null || echo UNBOUND)
    override=$(cat /sys/bus/pci/devices/$pci/driver_override 2>/dev/null)
    [ "$override" = "vfio-pci" ] || override=""
    if [ "$driver" != "vfio-pci" ] && [ "$driver" != "UNBOUND" ] && [ -z "$override" ]; then
      continue
    fi
    echo "" > /sys/bus/pci/devices/$pci/driver_override
    [ -e /sys/bus/pci/devices/$pci/driver/unbind ] && echo $pci > /sys/bus/pci/devices/$pci/driver/unbind
    echo $pci > /sys/bus/pci/drivers/mlx5_core/bind 2>/dev/null || true
    new_driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver 2>/dev/null) 2>/dev/null || echo UNBOUND)
    echo "Rebound $pci driver $driver -> $new_driver"
  done
done
'
    done
    log [INFO] "Stale VF cleanup finished"
}

function enable_kata() {
    local required_machineconfigs="99-kata-dpu-layered,99-iommu-enable"
    get_kubeconfig

    worker_role=$(kata_worker_role)
    log [INFO] "Enabling Kata DPU cold-plug on MCP '${worker_role}'"

    if [ "${KATA_ENABLED}" != "true" ]; then
        log [ERROR] "KATA_ENABLED is not true. Set KATA_ENABLED=true and re-run make enable-ovn-injector, then make enable-kata."
        exit 1
    fi

    assert_worker_dpu_pool
    validate_layer_image

    if ! oc get net-attach-def -n "${OVNK_NAMESPACE}" "${KATA_NAD_NAME}" &>/dev/null; then
        log [ERROR] "NetworkAttachmentDefinition '${KATA_NAD_NAME}' not found in ${OVNK_NAMESPACE}."
        log [ERROR] "Set KATA_ENABLED=true and run make enable-ovn-injector before make enable-kata."
        exit 1
    fi

    assert_no_legacy_osc_state
    wait_for_mcp "${worker_role}"
    check_kvm_on_workers

    mkdir -p "${GENERATED_KATA_DIR}"

    # Complete read-only checks before changing the DPF VF pool or worker MCP.
    ensure_kata_sriov_pool
    ensure_machineconfigs

    if [ "${KATA_MC_APPLIED}" = "true" ]; then
        log [INFO] "Waiting for MCO to pick up new MachineConfigs..."
        sleep 20
    else
        log [INFO] "Kata MachineConfigs already exist; waiting for MCP ${worker_role} rollout if needed"
    fi
    wait_for_mcp "${worker_role}" "${KATA_RHCOS_LAYER_IMAGE}" "${required_machineconfigs}"
    ensure_crio_handler_compat_machineconfig
    if [ "${KATA_COMPAT_MC_REQUIRED}" = "true" ]; then
        required_machineconfigs+=",50-kata-coldplug-handler"
    fi
    wait_for_mcp "${worker_role}" "${KATA_RHCOS_LAYER_IMAGE}" "${required_machineconfigs}"
    verify_layer_on_nodes
    log [INFO] "Rechecking MCP ${worker_role} health after node verification..."
    wait_for_mcp "${worker_role}" "${KATA_RHCOS_LAYER_IMAGE}"

    ensure_runtimeclass "${KATA_RUNTIME_CLASS}"
    render_kata_test_deployment

    log [INFO] "Layer-only Kata DPU cold-plug enabled (RuntimeClass ${KATA_RUNTIME_CLASS} on role ${worker_role})"
    log [INFO] "Deploy test pods: make deploy-kata-test   (or KATA_TEST_REPLICAS=N make deploy-kata-test)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-enable}" in
        enable)
            enable_kata
            ;;
        deploy-test)
            deploy_kata_test
            ;;
        cleanup-vfs)
            cleanup_stale_vfs
            ;;
        *)
            log [ERROR] "Unknown command: $1"
            log [ERROR] "Available commands: enable, deploy-test, cleanup-vfs"
            exit 1
            ;;
    esac
fi
