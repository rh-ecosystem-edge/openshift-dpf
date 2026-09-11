#!/bin/bash
# enable-kata.sh - Install OSC and kata-coldplug host support on DPU workers
#
# Validates each component first and only creates it when missing.
# DPU workers stay on MCP worker-dpu. OSC stays installed; KataConfig uses a
# selector that matches no nodes so OSC does not add node-role kata-oc
# (that plus worker-dpu is "belongs to 2 custom roles").
# Creates RuntimeClass kata-coldplug when missing.
#
# Run after enable-ovn-injector with KATA_ENABLED=true so the kata NAD exists.
# Not part of make all.

set -e
set -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"

KATA_MANIFESTS_DIR="${MANIFESTS_DIR}/kata"
GENERATED_KATA_DIR="${GENERATED_DIR}/kata"
OSC_NAMESPACE="openshift-sandboxed-containers-operator"
KATA_MC_APPLIED=false

# DPU hosts are in MCP worker-dpu even when the management cluster is SNO.
function kata_worker_role() {
    if oc get mcp worker-dpu &>/dev/null; then
        echo "worker-dpu"
    else
        echo "worker"
    fi
}

function wait_for_api() {
    log [INFO] "Waiting for API to return..."
    until oc get nodes &>/dev/null; do
        sleep 15
    done
}

function osc_csv_phase() {
    local phase
    phase=$(oc -n "${OSC_NAMESPACE}" get csv \
        -l operators.coreos.com/sandboxed-containers-operator.openshift-sandboxed-containers-operator \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [ -n "${phase}" ]; then
        echo "${phase}"
        return 0
    fi
    oc -n "${OSC_NAMESPACE}" get csv \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true
}

function wait_for_osc_csv() {
    log [INFO] "Waiting for OSC operator CSV to reach Succeeded..."
    local attempts=0
    local phase=""
    while [ $attempts -lt 60 ]; do
        phase=$(osc_csv_phase)
        if [ "$phase" = "Succeeded" ]; then
            log [INFO] "OSC operator CSV is Succeeded"
            return 0
        fi
        attempts=$((attempts + 1))
        log [INFO] "OSC CSV phase='${phase}' (attempt ${attempts}/60)"
        sleep 10
    done
    log [ERROR] "OSC operator CSV did not reach Succeeded after 10 minutes (last phase: '${phase}')"
    oc -n "${OSC_NAMESPACE}" get csv || true
    return 1
}

function ensure_osc() {
    if [ "$(osc_csv_phase)" = "Succeeded" ]; then
        log [INFO] "OSC operator already installed (CSV Succeeded), skipping create"
        return 0
    fi

    log [INFO] "Installing OpenShift Sandboxed Containers operator..."
    apply_manifest "${KATA_MANIFESTS_DIR}/01-osc-operator.yaml" "true"
    wait_for_osc_csv
}

# Selector matches no nodes so OSC does not label DPU hosts kata-oc.
function ensure_kataconfig() {
    log [INFO] "Waiting for KataConfig CRD..."
    oc wait --for=condition=Established crd/kataconfigs.kataconfiguration.openshift.io --timeout=120s
    log [INFO] "Applying KataConfig example-kataconfig (selector matches no nodes; DPU hosts stay on worker-dpu)"
    apply_manifest "${KATA_MANIFESTS_DIR}/02-kataconfig.yaml" "true"
}

function warn_if_dpu_nodes_have_kata_oc_role() {
    local labeled
    labeled=$(oc get nodes -l node-role.kubernetes.io/kata-oc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "${labeled}" ]; then
        log [WARN] "Nodes have node-role.kubernetes.io/kata-oc (conflicts with worker-dpu): ${labeled}"
        log [WARN] "Remove it: oc label node <name> node-role.kubernetes.io/kata-oc-"
    fi
}

function wait_for_mcp() {
    local pool=$1
    log [INFO] "Waiting for MachineConfigPool ${pool} to finish rolling out (nodes may reboot)..."
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

        local ready total updated degraded
        ready=$(oc get mcp "${pool}" -o jsonpath='{.status.readyMachineCount}' 2>/dev/null || echo "")
        total=$(oc get mcp "${pool}" -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "")
        updated=$(oc get mcp "${pool}" -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo "")
        degraded=$(oc get mcp "${pool}" -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo "0")

        log [INFO] "MCP ${pool}: ready=${ready:-?}/${total:-?} updated=${updated:-?} degraded=${degraded:-?}"

        if [ "${degraded:-0}" != "0" ]; then
            log [ERROR] "MachineConfigPool ${pool} is degraded"
            oc get mcp "${pool}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' || true
            echo
            return 1
        fi

        if [ -n "$ready" ] && [ -n "$total" ] && [ "$total" != "0" ] \
            && [ "$ready" = "$total" ] && [ "$updated" = "$total" ]; then
            log [INFO] "MachineConfigPool ${pool} is fully updated"
            return 0
        fi

        sleep 20
    done

    log [ERROR] "Timed out waiting for MachineConfigPool ${pool} after ${max_attempts} attempts"
    oc get mcp "${pool}" || true
    return 1
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
    local existing_role
    existing_role=$(oc get machineconfig "${name}" \
        -o jsonpath='{.metadata.labels.machineconfiguration\.openshift\.io/role}' 2>/dev/null || true)
    if [ "${existing_role}" = "${worker_role}" ]; then
        log [INFO] "MachineConfig ${name} already exists, skipping create"
        return 0
    fi
    log [INFO] "Creating MachineConfig ${name} (role ${worker_role})"
    render_kata_manifest \
        "${src}" \
        "${GENERATED_KATA_DIR}/$(basename "${src}")" \
        "<KATA_MC_ROLE>" "${worker_role}" \
        "$@"
    apply_manifest "${GENERATED_KATA_DIR}/$(basename "${src}")" "true"
    KATA_MC_APPLIED=true
}

function ensure_machineconfigs() {
    if oc get machineconfig 99-kata-dpu &>/dev/null; then
        log [INFO] "Removing combined MachineConfig 99-kata-dpu (replaced by split MCs)"
        oc delete machineconfig 99-kata-dpu
        KATA_MC_APPLIED=true
    fi

    if [ "${KATA_SKIP_RHCOS_LAYER}" = "true" ]; then
        log [INFO] "KATA_SKIP_RHCOS_LAYER=true: omitting RHCOS layer MachineConfig (z-stream kata RPM path)"
        if oc get machineconfig 99-kata-dpu-layered &>/dev/null; then
            log [INFO] "Deleting leftover MachineConfig 99-kata-dpu-layered"
            oc delete machineconfig 99-kata-dpu-layered
            KATA_MC_APPLIED=true
        fi
    else
        ensure_one_machineconfig 99-kata-dpu-layered \
            "${KATA_MANIFESTS_DIR}/03-rhcos-layer.yaml" \
            "<KATA_RHCOS_LAYER_IMAGE>" "${KATA_RHCOS_LAYER_IMAGE}"
    fi

    ensure_one_machineconfig 99-iommu-enable \
        "${KATA_MANIFESTS_DIR}/03-iommu.yaml"
    ensure_one_machineconfig 50-kata-coldplug-config \
        "${KATA_MANIFESTS_DIR}/04-kata-coldplug.yaml"
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
    local nodes node
    nodes=$(oc get nodes -l "node-role.kubernetes.io/${worker_role}=" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${nodes}" ]; then
        log [WARN] "No nodes with role ${worker_role} found; skipping /dev/kvm check"
        return 0
    fi
    for node in ${nodes}; do
        log [INFO] "Checking /dev/kvm on ${node}..."
        if ! oc debug "node/${node}" --quiet -- chroot /host test -e /dev/kvm; then
            log [ERROR] "/dev/kvm missing on ${node} (VMX/SVM disabled in BIOS). Enable virtualization and cold-boot the host before enable-kata."
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
    nodes=$(oc get nodes -l "node-role.kubernetes.io/${worker_role}=" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${nodes}" ]; then
        log [ERROR] "No nodes with role ${worker_role} found"
        exit 1
    fi

    # Failed kata pods leave driver_override=vfio-pci; the next pod gets a VF
    # with no netdev. Rebind those VFs to mlx5_core (jensfr stale VF cleanup).
    for node in ${nodes}; do
        log [INFO] "Rebinding stale VFIO VFs on ${node}..."
        oc debug "node/${node}" --quiet -- chroot /host bash -c '
for pf in $(ls /sys/class/net | grep np); do
  for vf in /sys/class/net/$pf/device/virtfn*; do
    [ -e "$vf" ] || continue
    pci=$(basename $(readlink $vf))
    driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver 2>/dev/null) 2>/dev/null || echo UNBOUND)
    override=$(cat /sys/bus/pci/devices/$pci/driver_override 2>/dev/null)
    if [ "$driver" != "mlx5_core" ] || { [ -n "$override" ] && [ "$override" != "(null)" ]; }; then
      echo "" > /sys/bus/pci/devices/$pci/driver_override
      [ -e /sys/bus/pci/devices/$pci/driver/unbind ] && echo $pci > /sys/bus/pci/devices/$pci/driver/unbind
      echo $pci > /sys/bus/pci/drivers/mlx5_core/bind 2>/dev/null
      echo "Fixed $pci (was driver=$driver override=${override:-none})"
    fi
  done
done
'
    done
    log [INFO] "Stale VF cleanup finished"
}

function enable_kata() {
    get_kubeconfig

    worker_role=$(kata_worker_role)
    log [INFO] "Enabling Kata DPU cold-plug on MCP '${worker_role}'"

    if ! oc get mcp "${worker_role}" &>/dev/null; then
        log [ERROR] "MachineConfigPool ${worker_role} not found. Deploy DPF / dpu-worker-config first."
        exit 1
    fi

    if [ "${KATA_ENABLED}" != "true" ]; then
        log [ERROR] "KATA_ENABLED is not true. Set KATA_ENABLED=true and re-run make enable-ovn-injector, then make enable-kata."
        exit 1
    fi

    if ! oc get net-attach-def -n "${OVNK_NAMESPACE}" "${KATA_NAD_NAME}" &>/dev/null; then
        log [ERROR] "NetworkAttachmentDefinition '${KATA_NAD_NAME}' not found in ${OVNK_NAMESPACE}."
        log [ERROR] "Set KATA_ENABLED=true and run make enable-ovn-injector before make enable-kata."
        exit 1
    fi

    check_kvm_on_workers

    mkdir -p "${GENERATED_KATA_DIR}"

    # KataConfig selector matches no nodes. Do not label DPU hosts kata-oc.
    ensure_osc
    ensure_kataconfig
    warn_if_dpu_nodes_have_kata_oc_role
    ensure_machineconfigs

    if [ "${KATA_MC_APPLIED}" = "true" ]; then
        log [INFO] "Waiting for MCO to pick up new MachineConfigs..."
        sleep 20
    else
        log [INFO] "Kata MachineConfigs already exist; waiting for MCP ${worker_role} rollout if needed"
    fi
    wait_for_mcp "${worker_role}"

    ensure_runtimeclass "${KATA_RUNTIME_CLASS}"
    render_kata_test_deployment

    log [INFO] "Kata DPU cold-plug enabled (RuntimeClass ${KATA_RUNTIME_CLASS} on role ${worker_role})"
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
