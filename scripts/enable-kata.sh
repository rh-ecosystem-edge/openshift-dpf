#!/bin/bash
# enable-kata.sh - Install OSC and kata-coldplug host support on DPU workers
#
# Validates each component first and only creates it when missing.
# MachineConfigs go on the existing worker-dpu (or worker on SNO) MCP.
# Does NOT create a KataConfig CR: OSC's kata-oc pool would clash with
# worker-dpu and degrade MCO. Creates RuntimeClass kata-coldplug when missing.
#
# Run after enable-ovn-injector so the kata NAD already exists.
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

function kata_worker_role() {
    if [[ "${VM_COUNT:-0}" -eq 1 ]]; then
        echo "worker"
    else
        echo "worker-dpu"
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

function ensure_machineconfig() {
    local name="99-kata-dpu"
    if oc get machineconfig "${name}" &>/dev/null; then
        log [INFO] "MachineConfig ${name} already exists, skipping create"
        return 0
    fi

    local os_image_line=""
    if [ "${KATA_SKIP_RHCOS_LAYER}" = "true" ]; then
        log [INFO] "KATA_SKIP_RHCOS_LAYER=true: omitting osImageURL (z-stream kata RPM path)"
    else
        os_image_line="osImageURL: ${KATA_RHCOS_LAYER_IMAGE}"
    fi

    log [INFO] "Creating MachineConfig ${name}"
    render_kata_manifest \
        "${KATA_MANIFESTS_DIR}/02-kata-machineconfig.yaml" \
        "${GENERATED_KATA_DIR}/02-kata-machineconfig.yaml" \
        "<WORKER_ROLE>" "${worker_role}" \
        "<KATA_OS_IMAGE_URL>" "${os_image_line}"
    apply_manifest "${GENERATED_KATA_DIR}/02-kata-machineconfig.yaml" "true"
    KATA_MC_APPLIED=true
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
    if wait_for_runtimeclass "${name}" 6; then
        return 0
    fi

    log [INFO] "RuntimeClass ${name} not found; creating from 05-runtimeclass.yaml"
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
        "<KATA_INJECTOR_RESOURCE_NAME>" "${KATA_INJECTOR_RESOURCE_NAME}" \
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

function enable_kata() {
    get_kubeconfig

    worker_role=$(kata_worker_role)
    log [INFO] "Enabling Kata DPU cold-plug on MCP role '${worker_role}'"

    if ! oc get mcp "${worker_role}" &>/dev/null; then
        log [ERROR] "MachineConfigPool ${worker_role} not found. Deploy DPF / dpu-worker-config first."
        exit 1
    fi

    mkdir -p "${GENERATED_KATA_DIR}"

    # Intentionally no KataConfig CR. OSC would create MCP kata-oc and pull
    # DPU workers out of worker-dpu, degrading MCO.
    ensure_osc

    ensure_machineconfig

    if [ "${KATA_MC_APPLIED}" = "true" ]; then
        log [INFO] "Waiting for MCO to pick up new MachineConfigs..."
        sleep 20
    else
        log [INFO] "MachineConfig 99-kata-dpu already exists; waiting for MCP ${worker_role} rollout if needed"
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
        *)
            log [ERROR] "Unknown command: $1"
            log [ERROR] "Available commands: enable, deploy-test"
            exit 1
            ;;
    esac
fi
