#!/bin/bash
# verify.sh - Deployment verification for DPF
#
# Verifies:
# 1. Worker nodes are Ready in host cluster
# 2. DPU nodes are Ready in DPUCluster
# 3. DPUDeployment is Ready

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

VERIFY_MAX_RETRIES="${VERIFY_MAX_RETRIES:-60}"
VERIFY_SLEEP_SECONDS="${VERIFY_SLEEP_SECONDS:-30}"

# -----------------------------------------------------------------------------
# 1. Worker Nodes (host cluster)
# -----------------------------------------------------------------------------
verify_worker_nodes() {
    local expected_count="${WORKER_COUNT:-0}"
    
    if [[ "$expected_count" -eq 0 ]]; then
        log "INFO" "WORKER_COUNT=0, skipping worker node verification"
        return 0
    fi
    
    log "INFO" "Waiting for $expected_count worker node(s) to be Ready..."

    if retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" bash -c '
        expected="$1"
        ready_workers=$(oc get nodes -l "!node-role.kubernetes.io/control-plane" -o json | jq "[.items[] | select(.status.conditions[] | select(.type==\"Ready\" and .status==\"True\"))] | length")
        echo "Worker nodes: $ready_workers/$expected Ready"
        [[ "$ready_workers" -ge "$expected" ]]
    ' _ "$expected_count"; then
        log "INFO" "All $expected_count worker node(s) are Ready"
        oc get nodes -l "!node-role.kubernetes.io/control-plane"
        return 0
    fi

    log "ERROR" "Timed out waiting for worker nodes"
    oc get nodes -l "!node-role.kubernetes.io/control-plane"
    return 1
}

# -----------------------------------------------------------------------------
# 2. DPU Nodes (DPUCluster / Hypershift hosted cluster)
# -----------------------------------------------------------------------------
verify_dpu_nodes() {
    local expected_count="${WORKER_COUNT:-0}"
    
    if [[ "$expected_count" -eq 0 ]]; then
        log "INFO" "WORKER_COUNT=0, skipping DPU node verification"
        return 0
    fi
    
    local hosted_kubeconfig="${HOSTED_CLUSTER_NAME}.kubeconfig"
    
    if [[ ! -f "$hosted_kubeconfig" ]]; then
        log "INFO" "Fetching DPUCluster kubeconfig..."
        if ! oc get secret -n "${CLUSTERS_NAMESPACE}" "${HOSTED_CLUSTER_NAME}-admin-kubeconfig" &>/dev/null; then
            log "WARN" "DPUCluster kubeconfig not found, skipping"
            return 0
        fi
        oc get secret -n "${CLUSTERS_NAMESPACE}" "${HOSTED_CLUSTER_NAME}-admin-kubeconfig" \
            -o jsonpath='{.data.kubeconfig}' | base64 -d > "$hosted_kubeconfig"
    fi
    
    log "INFO" "Waiting for $expected_count DPU node(s) to be Ready in DPUCluster..."

    if retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" bash -c '
        expected="$1"
        kubeconfig="$2"
        ready_dpus=$(KUBECONFIG="$kubeconfig" oc get nodes -l node-role.kubernetes.io/worker= -o json 2>/dev/null \
            | jq "[.items[] | select(.status.conditions[] | select(.type==\"Ready\" and .status==\"True\"))] | length")
        echo "DPU nodes: $ready_dpus/$expected Ready"
        [[ "$ready_dpus" -ge "$expected" ]]
    ' _ "$expected_count" "$hosted_kubeconfig"; then
        log "INFO" "All $expected_count DPU node(s) are Ready in DPUCluster"
        KUBECONFIG="$hosted_kubeconfig" oc get nodes -l node-role.kubernetes.io/worker=
        return 0
    fi

    log "ERROR" "Timed out waiting for DPU nodes"
    KUBECONFIG="$hosted_kubeconfig" oc get nodes -l node-role.kubernetes.io/worker=
    return 1
}

# -----------------------------------------------------------------------------
# 3. DPUDeployment
# -----------------------------------------------------------------------------
verify_dpudeployment() {
    local name="dpudeployment"
    local namespace="dpf-operator-system"

    if ! oc get dpudeployment -n "$namespace" "$name" &>/dev/null; then
        log "WARN" "DPUDeployment not found, skipping"
        return 0
    fi

    log "INFO" "Waiting for DPUDeployment to be Ready..."

    if retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" bash -c '
        ns="$1"
        name="$2"
        ready_status=$(oc get dpudeployment -n "$ns" "$name" \
            -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" 2>/dev/null || echo "")
        echo "DPUDeployment Ready=$ready_status"
        [[ "$ready_status" == "True" ]]
    ' _ "$namespace" "$name"; then
        log "INFO" "DPUDeployment is Ready"
        oc get dpudeployment -n "$namespace" "$name"
        return 0
    fi

    log "ERROR" "Timed out waiting for DPUDeployment"
    oc get dpudeployment -n "$namespace" "$name" -o yaml
    return 1
}

# -----------------------------------------------------------------------------
# Full Verification
# -----------------------------------------------------------------------------
verify_deployment() {
    if [[ "${VERIFY_DEPLOYMENT}" != "true" ]]; then
        log "INFO" "VERIFY_DEPLOYMENT is not set to true, skipping verification"
        log "INFO" "Run 'make verify-deployment' manually or set VERIFY_DEPLOYMENT=true"
        return 0
    fi

    log "INFO" "================================================================================"
    log "INFO" "Starting deployment verification..."
    log "INFO" "================================================================================"
    
    local failed=0
    
    log "INFO" ""
    log "INFO" "=== 1. Verifying Worker Nodes ==="
    if ! verify_worker_nodes; then
        ((failed++)) || true
    fi
    
    log "INFO" ""
    log "INFO" "=== 2. Verifying DPU Nodes ==="
    if ! verify_dpu_nodes; then
        ((failed++)) || true
    fi
    
    log "INFO" ""
    log "INFO" "=== 3. Verifying DPUDeployment ==="
    if ! verify_dpudeployment; then
        ((failed++)) || true
    fi
    
    log "INFO" ""
    log "INFO" "================================================================================"
    if [[ $failed -eq 0 ]]; then
        log "INFO" "All verification checks PASSED"
        return 0
    else
        log "ERROR" "$failed verification check(s) FAILED"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Command Dispatcher
# -----------------------------------------------------------------------------
case "${1:-}" in
    verify-workers)       verify_worker_nodes ;;
    verify-dpu-nodes)     verify_dpu_nodes ;;
    verify-dpudeployment) verify_dpudeployment ;;
    verify-deployment)    verify_deployment ;;
    *)
        echo "Usage: $0 {verify-workers|verify-dpu-nodes|verify-dpudeployment|verify-deployment}"
        exit 1
        ;;
esac
