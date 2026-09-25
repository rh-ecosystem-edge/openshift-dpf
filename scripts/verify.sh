#!/bin/bash
# verify.sh - Deployment verification for DPF
#
# Verifies (in provisioning order):
# 1. Management (host) cluster workers join (node registered; Ready not required)
# 2. DPU CRs reach phase Ready on the management cluster
# 3. DPU worker nodes are Ready on the hosted cluster
# 4. Management (host) cluster worker nodes are Ready
# 5. DPUDeployment is Ready

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

VERIFY_MAX_RETRIES="${VERIFY_MAX_RETRIES:-60}"
VERIFY_SLEEP_SECONDS="${VERIFY_SLEEP_SECONDS:-30}"
DPF_OPERATOR_NAMESPACE="${DPF_OPERATOR_NAMESPACE:-dpf-operator-system}"
DPU_DEPLOYMENT_NAME="${DPU_DEPLOYMENT_NAME:-dpudeployment}"

# Ordered verify-deployment steps and failures (for end summary).
VERIFY_DEPLOYMENT_STEPS=(
    verify_worker_nodes_joined
    verify_dpu_objects
    verify_dpu_nodes
    verify_worker_nodes
    verify_dpudeployment
    verify_management_cluster_stable
    verify_hosted_cluster_stable
)
VERIFY_FAILED_STEPS=()

_verify_step_failed() {
    local step="$1"
    local failed
    for failed in "${VERIFY_FAILED_STEPS[@]}"; do
        [[ "$failed" == "$step" ]] && return 0
    done
    return 1
}

_verify_print_summary() {
    local step
    for step in "${VERIFY_DEPLOYMENT_STEPS[@]}"; do
        if _verify_step_failed "$step"; then
            log "ERROR" "  FAILED: ${step}"
        else
            log "INFO" "  PASSED: ${step}"
        fi
    done
}

# -----------------------------------------------------------------------------
# Kubeconfig
# -----------------------------------------------------------------------------
# Returns 0 on success, 1 if secret missing (skip hosted checks), 2 on error.
ensure_hosted_kubeconfig() {
    HOSTED_KUBECONFIG="${HOSTED_CLUSTER_NAME}.kubeconfig"

    if [[ -f "$HOSTED_KUBECONFIG" ]] && [[ -s "$HOSTED_KUBECONFIG" ]]; then
        return 0
    fi

    log "INFO" "Fetching DPUCluster kubeconfig..."
    local secret_name="${HOSTED_CLUSTER_NAME}-admin-kubeconfig"
    local get_output
    if ! get_output=$(oc get secret -n "${CLUSTERS_NAMESPACE}" "$secret_name" -o name 2>&1); then
        if echo "$get_output" | grep -q "NotFound"; then
            log "WARN" "DPUCluster kubeconfig secret not found"
            return 1
        fi
        log "ERROR" "Failed to query secret ${secret_name}: ${get_output}"
        return 2
    fi

    local tmpfile="${HOSTED_KUBECONFIG}.tmp"
    if ! oc get secret -n "${CLUSTERS_NAMESPACE}" "$secret_name" \
        -o jsonpath='{.data.kubeconfig}' | base64 -d > "$tmpfile"; then
        log "ERROR" "Failed to decode kubeconfig from secret ${secret_name}"
        rm -f "$tmpfile"
        return 2
    fi

    if [[ ! -s "$tmpfile" ]]; then
        log "ERROR" "Decoded kubeconfig from secret ${secret_name} is empty"
        rm -f "$tmpfile"
        return 2
    fi

    mv "$tmpfile" "$HOSTED_KUBECONFIG"
}

# -----------------------------------------------------------------------------
# Readiness probes (single-shot; suitable for retry + final recheck)
# -----------------------------------------------------------------------------
_count_management_workers_joined() {
    oc get nodes -l '!node-role.kubernetes.io/control-plane' -o json 2>/dev/null \
        | jq '.items | length'
}

check_management_workers_joined() {
    local expected_count="$1"
    local joined_workers
    joined_workers=$(_count_management_workers_joined)
    echo "Management (host) cluster workers joined: ${joined_workers}/${expected_count}"
    [[ "$joined_workers" -ge "$expected_count" ]]
}

_count_ready_management_workers() {
    oc get nodes -l '!node-role.kubernetes.io/control-plane' -o json 2>/dev/null \
        | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length'
}

check_management_workers_ready() {
    local expected_count="$1"
    local ready_workers
    ready_workers=$(_count_ready_management_workers)
    echo "Management (host) cluster workers Ready: ${ready_workers}/${expected_count}"
    [[ "$ready_workers" -ge "$expected_count" ]]
}

_count_ready_hosted_dpu_workers() {
    local kubeconfig="$1"
    KUBECONFIG="$kubeconfig" oc get nodes -l node-role.kubernetes.io/worker= -o json 2>/dev/null \
        | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length'
}

check_hosted_dpu_workers_ready() {
    local expected_count="$1"
    local kubeconfig="$2"
    local ready_dpus
    ready_dpus=$(_count_ready_hosted_dpu_workers "$kubeconfig")
    echo "Hosted cluster DPU workers Ready: ${ready_dpus}/${expected_count}"
    [[ "$ready_dpus" -ge "$expected_count" ]]
}

_count_ready_dpu_objects() {
    local namespace="${1:-$DPF_OPERATOR_NAMESPACE}"
    oc get dpu -n "$namespace" -o json 2>/dev/null \
        | jq '[.items[] | select(.status.phase == "Ready")] | length'
}

check_dpu_objects_ready() {
    local expected_count="$1"
    local namespace="${2:-$DPF_OPERATOR_NAMESPACE}"
    local ready_dpus
    ready_dpus=$(_count_ready_dpu_objects "$namespace")
    echo "DPU objects (phase=Ready) in ${namespace}: ${ready_dpus}/${expected_count}"
    [[ "$ready_dpus" -ge "$expected_count" ]]
}

check_dpudeployment_ready() {
    local namespace="${1:-$DPF_OPERATOR_NAMESPACE}"
    local name="${2:-$DPU_DEPLOYMENT_NAME}"
    local ready_status
    ready_status=$(oc get dpudeployment -n "$namespace" "$name" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    echo "DPUDeployment Ready=${ready_status}"
    [[ "$ready_status" == "True" ]]
}

# Run one verification function; record failure but do not abort the pipeline.
verify_invoke() {
    local step_fn="$1"

    echo ""
    if "$step_fn"; then
        log "INFO" "CHECK PASSED: ${step_fn}"
        return 0
    fi

    log "ERROR" "CHECK FAILED: ${step_fn}"
    VERIFY_FAILED_STEPS+=("$step_fn")
    return 1
}

# -----------------------------------------------------------------------------
# Verification steps (each function is self-contained; callable from make / CLI)
# -----------------------------------------------------------------------------
verify_worker_nodes_joined() {
    log "INFO" "=== Management (host) cluster workers (joined) ==="
    local expected_count="${WORKER_COUNT:-0}"

    if [[ "$expected_count" -eq 0 ]]; then
        log "INFO" "WORKER_COUNT=0, skipping management host worker join verification"
        return 0
    fi

    log "INFO" "Waiting for ${expected_count} management (host) worker node(s) to join the cluster"
    log "INFO" "(Node must exist; Ready is not required yet.)"

    if retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" check_management_workers_joined "$expected_count"; then
        log "INFO" "${expected_count} management (host) worker node(s) have joined"
        oc get nodes -l '!node-role.kubernetes.io/control-plane' -o wide
        return 0
    fi

    log "ERROR" "Timed out waiting for management (host) cluster workers to join"
    oc get nodes -l '!node-role.kubernetes.io/control-plane' -o wide
    return 1
}

verify_worker_nodes() {
    log "INFO" "=== Management (host) cluster workers (Ready) ==="
    local expected_count="${WORKER_COUNT:-0}"

    if [[ "$expected_count" -eq 0 ]]; then
        log "INFO" "WORKER_COUNT=0, skipping management host worker verification"
        return 0
    fi

    log "INFO" "Waiting for ${expected_count} management (host) cluster worker(s) to be Ready"
    log "INFO" "(After DPU CRs and hosted DPU workers are Ready.)"

    if retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" check_management_workers_ready "$expected_count"; then
        log "INFO" "All ${expected_count} management (host) worker(s) are Ready"
        oc get nodes -l '!node-role.kubernetes.io/control-plane' -o wide
        return 0
    fi

    log "ERROR" "Timed out waiting for management (host) cluster workers"
    oc get nodes -l '!node-role.kubernetes.io/control-plane' -o wide
    return 1
}

verify_dpu_nodes() {
    log "INFO" "=== Hosted cluster DPU worker nodes ==="
    local expected_count="${WORKER_COUNT:-0}"

    if [[ "$expected_count" -eq 0 ]]; then
        log "INFO" "WORKER_COUNT=0, skipping hosted DPU worker verification"
        return 0
    fi

    ensure_hosted_kubeconfig
    local rc=$?
    if [[ $rc -eq 1 ]]; then
        log "WARN" "Skipping hosted DPU worker verification"
        return 0
    elif [[ $rc -ne 0 ]]; then
        return 1
    fi

    log "INFO" "Waiting for ${expected_count} DPU worker node(s) on the hosted cluster to be Ready"

    if retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" \
        check_hosted_dpu_workers_ready "$expected_count" "$HOSTED_KUBECONFIG"; then
        log "INFO" "All ${expected_count} hosted cluster DPU worker(s) are Ready"
        KUBECONFIG="$HOSTED_KUBECONFIG" oc get nodes -l node-role.kubernetes.io/worker=
        return 0
    fi

    log "ERROR" "Timed out waiting for hosted DPU workers"
    KUBECONFIG="$HOSTED_KUBECONFIG" oc get nodes -l node-role.kubernetes.io/worker=
    return 1
}

verify_dpu_objects() {
    log "INFO" "=== DPU objects (management cluster) ==="
    local expected_count="${WORKER_COUNT:-0}"

    if [[ "$expected_count" -eq 0 ]]; then
        log "INFO" "WORKER_COUNT=0, skipping DPU object verification"
        return 0
    fi

    if ! oc get crd dpus.provisioning.dpu.nvidia.com &>/dev/null; then
        log "WARN" "DPU CRD not found, skipping DPU object verification"
        return 0
    fi

    log "INFO" "Waiting for ${expected_count} DPU object(s) to reach phase Ready in ${DPF_OPERATOR_NAMESPACE}"

    if retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" \
        check_dpu_objects_ready "$expected_count" "$DPF_OPERATOR_NAMESPACE"; then
        log "INFO" "All ${expected_count} DPU object(s) are Ready"
        oc get dpu -n "$DPF_OPERATOR_NAMESPACE"
        return 0
    fi

    log "ERROR" "Timed out waiting for DPU objects to reach phase Ready"
    oc get dpu -n "$DPF_OPERATOR_NAMESPACE" -o wide 2>/dev/null || oc get dpu -n "$DPF_OPERATOR_NAMESPACE"
    return 1
}

verify_dpudeployment() {
    log "INFO" "=== DPUDeployment ==="
    if ! oc get dpudeployment -n "$DPF_OPERATOR_NAMESPACE" "$DPU_DEPLOYMENT_NAME" &>/dev/null; then
        log "WARN" "DPUDeployment not found, skipping"
        return 0
    fi

    log "INFO" "Waiting for DPUDeployment to be Ready..."

    if retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" \
        check_dpudeployment_ready "$DPF_OPERATOR_NAMESPACE" "$DPU_DEPLOYMENT_NAME"; then
        log "INFO" "DPUDeployment is Ready"
        oc get dpudeployment -n "$DPF_OPERATOR_NAMESPACE" "$DPU_DEPLOYMENT_NAME"
        return 0
    fi

    log "ERROR" "Timed out waiting for DPUDeployment"
    oc get dpudeployment -n "$DPF_OPERATOR_NAMESPACE" "$DPU_DEPLOYMENT_NAME" -o yaml
    return 1
}

verify_management_cluster_stable() {
    log "INFO" "=== Management cluster operator stability ==="
    if oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=20m; then
        return 0
    fi
    return 1
}

verify_hosted_cluster_stable() {
    log "INFO" "=== Hosted cluster operator stability ==="
    ensure_hosted_kubeconfig
    local rc=$?
    if [[ $rc -eq 1 ]]; then
        log "WARN" "Skipping hosted cluster stability check (kubeconfig not available)"
        return 0
    elif [[ $rc -ne 0 ]]; then
        return 1
    fi

    if KUBECONFIG="$HOSTED_KUBECONFIG" oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=20m; then
        return 0
    fi
    return 1
}

verify_deployment() {
    if [[ "${VERIFY_DEPLOYMENT}" != "true" ]]; then
        log "INFO" "VERIFY_DEPLOYMENT is not set to true, skipping verification"
        log "INFO" "Run 'make verify-deployment' manually or set VERIFY_DEPLOYMENT=true"
        return 0
    fi

    VERIFY_FAILED_STEPS=()
    export VERIFY_RETRY_NO_DUMP=true

    log "INFO" "================================================================================"
    log "INFO" "Starting deployment verification..."
    log "INFO" "(Checks run in order; a failure in an early step does not skip later steps.)"
    log "INFO" "================================================================================"

    verify_invoke verify_worker_nodes_joined || true
    verify_invoke verify_dpu_objects || true
    verify_invoke verify_dpu_nodes || true
    verify_invoke verify_worker_nodes || true
    verify_invoke verify_dpudeployment || true
    verify_invoke verify_management_cluster_stable || true
    verify_invoke verify_hosted_cluster_stable || true

    unset VERIFY_RETRY_NO_DUMP

    log "INFO" "================================================================================"
    log "INFO" "Verification summary:"
    _verify_print_summary
    if [[ ${#VERIFY_FAILED_STEPS[@]} -eq 0 ]]; then
        log "INFO" "================================================================================"
        return 0
    fi

    log "ERROR" "${#VERIFY_FAILED_STEPS[@]} verification check(s) FAILED"
    log "INFO" "================================================================================"
    dump_system_status "deployment verification failed: ${VERIFY_FAILED_STEPS[*]}"
    return 1
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        verify-workers-joined) verify_worker_nodes_joined ;;
        verify-workers)       verify_worker_nodes ;;
        verify-dpu-nodes)     verify_dpu_nodes ;;
        verify-dpu-objects)   verify_dpu_objects ;;
        verify-dpudeployment) verify_dpudeployment ;;
        verify-deployment)    verify_deployment ;;
        *)
            echo "Usage: $0 {verify-workers-joined|verify-workers|verify-dpu-nodes|verify-dpu-objects|verify-dpudeployment|verify-deployment}"
            exit 1
            ;;
    esac
fi
