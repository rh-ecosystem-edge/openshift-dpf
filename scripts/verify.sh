#!/bin/bash
# verify.sh - Deployment verification for DPF
#
# Verifies (in provisioning order):
# 1. Management (host) cluster workers join (node registered; Ready not required)
# 2. DPU CRs reach phase Ready on the management cluster
# 3. DPU worker nodes are Ready on the hosted cluster
# 4. Management (host) cluster worker nodes are Ready
# 5. DPUDeployment is Ready
# 6. Management and hosted cluster operators are stable
#
# Zero Trust (verify-zt-deployment) has no host workers and verifies:
# 1. Every DPU listed in WORKER_<N>_DPU_BMC_IPS is Ready and its hosted Node is Ready
# 2. DPUDeployment is Ready
# 3. Hosted cluster operators are stable
#
# The management cluster is not part of the Zero Trust logic, so its cluster
# operators are not checked there.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

VERIFY_MAX_RETRIES="${VERIFY_MAX_RETRIES:-60}"
VERIFY_SLEEP_SECONDS="${VERIFY_SLEEP_SECONDS:-30}"
DPF_OPERATOR_NAMESPACE="${DPF_OPERATOR_NAMESPACE:-dpf-operator-system}"
DPU_DEPLOYMENT_NAME="${DPU_DEPLOYMENT_NAME:-${NICO_DPU_DEPLOYMENT_NAME:-dpudeployment}}"

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
VERIFY_ZT_DEPLOYMENT_STEPS=(
    verify_zt_dpus
    verify_zt_dpudeployment
    verify_hosted_cluster_stable
)
VERIFY_FAILED_STEPS=()
VERIFY_PASSED_STEPS=()

# Per-step failure dump is done in verify_invoke; avoid duplicate dumps from retry().
_verify_retry() {
    retry "$1" "$2" --no-dump-on-failure "${@:3}"
}

_verify_step_failed() {
    local step="$1"
    local failed
    for failed in "${VERIFY_FAILED_STEPS[@]}"; do
        [[ "$failed" == "$step" ]] && return 0
    done
    return 1
}

_verify_step_passed() {
    local step="$1"
    local passed
    for passed in "${VERIFY_PASSED_STEPS[@]}"; do
        [[ "$passed" == "$step" ]] && return 0
    done
    return 1
}

_verify_print_summary() {
    local step
    for step in "$@"; do
        if _verify_step_failed "$step"; then
            log "ERROR" "  FAILED: ${step}"
        elif _verify_step_passed "$step"; then
            log "INFO" "  PASSED: ${step}"
        else
            log "INFO" "  SKIPPED: ${step}"
        fi
    done
}

# -----------------------------------------------------------------------------
# Readiness probes (single-shot; suitable for retry + final recheck)
# -----------------------------------------------------------------------------
_expected_dpu_worker_count() {
    local worker_count="${WORKER_COUNT:-0}"
    local dpu_count=0
    local i

    for i in $(seq 1 "$worker_count"); do
        local dpu_var="WORKER_${i}_DPU"
        [[ "${!dpu_var:-true}" == "true" ]] && ((dpu_count++)) || true
    done
    echo "$dpu_count"
}

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

# Print the state of every DPU listed in WORKER_<N>_DPU_BMC_IPS. Succeeds when
# each DPU is in phase Ready and its hosted Node, which has the DPU's name, is Ready.
check_zt_dpus_ready() {
    local namespace="${1:-$DPF_OPERATOR_NAMESPACE}"
    local devices dpus nodes host bmc_ip device dpu phase node_ready
    local not_ready=0

    devices=$(oc get dpudevices.provisioning.dpu.nvidia.com -n "$namespace" -o json 2>/dev/null) || return 1
    dpus=$(oc get dpus.provisioning.dpu.nvidia.com -n "$namespace" -o json 2>/dev/null) || return 1
    nodes=$(KUBECONFIG="$HOSTED_KUBECONFIG" oc get nodes -o json 2>/dev/null) || nodes='{"items":[]}'

    while IFS= read -r host; do
        while IFS= read -r bmc_ip; do
            device=$(jq -r --arg ip "$bmc_ip" \
                '[.items[] | select(.spec.bmcIp == $ip) | .metadata.name] | if length == 1 then .[0] else "" end' <<< "$devices")
            dpu=$(jq -r --arg d "$device" \
                'first(.items[] | select($d != "" and .spec.dpuDeviceName == $d) | .metadata.name) // ""' <<< "$dpus")
            phase=$(jq -r --arg n "$dpu" \
                'first(.items[] | select(.metadata.name == $n) | .status.phase) // "none"' <<< "$dpus")
            node_ready=$(jq -r --arg n "$dpu" \
                'first(.items[] | select(.metadata.name == $n) | .status.conditions[]? | select(.type == "Ready") | .status) // "missing"' <<< "$nodes")
            echo "WORKER_${host} DPU BMC ${bmc_ip}: DPU ${dpu:-missing}, phase ${phase}, hosted Node Ready=${node_ready}"
            [[ "$phase" == "Ready" && "$node_ready" == "True" ]] || not_ready=1
        done < <(list_zero_trust_host_dpu_bmc_ips "$host")
    done < <(list_zero_trust_dpu_hosts)

    return "$not_ready"
}

# Print the phase and the conditions that are not True of every DPU that is not Ready.
_print_zt_dpu_conditions() {
    local namespace="${1:-$DPF_OPERATOR_NAMESPACE}"
    oc get dpus.provisioning.dpu.nvidia.com -n "$namespace" -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.phase != "Ready")
            | "DPU \(.metadata.name): phase \(.status.phase)",
              (.status.conditions[]? | select(.status != "True")
                | "  \(.type)=\(.status) \(.reason // ""): \(.message // "")")' || true
}

# Run one verification function; dump cluster state and stop the pipeline on failure.
verify_invoke() {
    local step_fn="$1"

    echo ""
    if "$step_fn"; then
        log "INFO" "CHECK PASSED: ${step_fn}"
        VERIFY_PASSED_STEPS+=("$step_fn")
        return 0
    fi

    log "ERROR" "CHECK FAILED: ${step_fn}"
    VERIFY_FAILED_STEPS+=("$step_fn")
    dump_system_status "verification check failed: ${step_fn}"
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

    if _verify_retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" check_management_workers_joined "$expected_count"; then
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

    if _verify_retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" check_management_workers_ready "$expected_count"; then
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
    local expected_count
    expected_count=$(_expected_dpu_worker_count)

    if [[ "$expected_count" -eq 0 ]]; then
        log "INFO" "No DPU workers configured (WORKER_*_DPU), skipping hosted DPU worker verification"
        return 0
    fi

    ensure_hosted_kubeconfig
    local rc=$?
    if [[ $rc -eq 1 ]]; then
        log "ERROR" "Hosted cluster kubeconfig not available; cannot verify DPU worker nodes"
        return 1
    elif [[ $rc -ne 0 ]]; then
        return 1
    fi

    log "INFO" "Waiting for ${expected_count} DPU worker node(s) on the hosted cluster to be Ready"

    if _verify_retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" \
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
    local expected_count
    expected_count=$(_expected_dpu_worker_count)

    if [[ "$expected_count" -eq 0 ]]; then
        log "INFO" "No DPU workers configured (WORKER_*_DPU), skipping DPU object verification"
        return 0
    fi

    if ! oc get crd dpus.provisioning.dpu.nvidia.com &>/dev/null; then
        log "WARN" "DPU CRD not found, skipping DPU object verification"
        return 0
    fi

    log "INFO" "Waiting for ${expected_count} DPU object(s) to reach phase Ready in ${DPF_OPERATOR_NAMESPACE}"

    if _verify_retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" \
        check_dpu_objects_ready "$expected_count" "$DPF_OPERATOR_NAMESPACE"; then
        log "INFO" "All ${expected_count} DPU object(s) are Ready"
        oc get dpu -n "$DPF_OPERATOR_NAMESPACE"
        return 0
    fi

    log "ERROR" "Timed out waiting for DPU objects to reach phase Ready"
    oc get dpu -n "$DPF_OPERATOR_NAMESPACE" -o wide 2>/dev/null || oc get dpu -n "$DPF_OPERATOR_NAMESPACE"
    return 1
}

verify_zt_dpus() {
    log "INFO" "=== Zero Trust DPUs (DPU objects and hosted cluster Nodes) ==="

    ensure_hosted_kubeconfig
    local rc=$?
    if [[ $rc -eq 1 ]]; then
        log "ERROR" "Hosted cluster kubeconfig not available; cannot verify the DPU Nodes"
        return 1
    elif [[ $rc -ne 0 ]]; then
        return 1
    fi

    log "INFO" "Waiting for every DPU in WORKER_<N>_DPU_BMC_IPS to reach phase Ready and join the hosted cluster"

    if _verify_retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" \
        check_zt_dpus_ready "$DPF_OPERATOR_NAMESPACE"; then
        log "INFO" "All listed DPUs are Ready"
        oc get dpu -n "$DPF_OPERATOR_NAMESPACE"
        return 0
    fi

    log "ERROR" "Timed out waiting for the listed DPUs"
    check_zt_dpus_ready "$DPF_OPERATOR_NAMESPACE" || true
    _print_zt_dpu_conditions "$DPF_OPERATOR_NAMESPACE"
    return 1
}

# Zero Trust always creates the DPUDeployment, so a missing one fails instead of skipping.
verify_zt_dpudeployment() {
    if ! oc get dpudeployment -n "$DPF_OPERATOR_NAMESPACE" "$DPU_DEPLOYMENT_NAME" &>/dev/null; then
        log "ERROR" "DPUDeployment ${DPU_DEPLOYMENT_NAME} not found in ${DPF_OPERATOR_NAMESPACE}"
        return 1
    fi
    verify_dpudeployment
}

verify_dpudeployment() {
    log "INFO" "=== DPUDeployment ==="
    if ! oc get dpudeployment -n "$DPF_OPERATOR_NAMESPACE" "$DPU_DEPLOYMENT_NAME" &>/dev/null; then
        log "WARN" "DPUDeployment not found, skipping"
        return 0
    fi

    log "INFO" "Waiting for DPUDeployment to be Ready..."

    if _verify_retry "$VERIFY_MAX_RETRIES" "$VERIFY_SLEEP_SECONDS" \
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
        log "INFO" "Run 'make verify-deployment' or set VERIFY_DEPLOYMENT=true in .env"
        return 0
    fi

    _verify_run_steps "${VERIFY_DEPLOYMENT_STEPS[@]}"
}

verify_zt_deployment() {
    if [[ "${DPF_DEPLOYMENT_MODE}" != "zero-trust" ]]; then
        log "ERROR" "Zero Trust verification requires DPF_DEPLOYMENT_MODE=zero-trust"
        return 1
    fi
    if [[ "${VERIFY_DEPLOYMENT}" != "true" ]]; then
        log "INFO" "VERIFY_DEPLOYMENT is not set to true, skipping verification"
        log "INFO" "Run 'make verify-zt-deployment' or set VERIFY_DEPLOYMENT=true in .env"
        return 0
    fi

    _verify_run_steps "${VERIFY_ZT_DEPLOYMENT_STEPS[@]}"
}

_verify_run_steps() {
    VERIFY_FAILED_STEPS=()
    VERIFY_PASSED_STEPS=()

    log "INFO" "================================================================================"
    log "INFO" "Starting deployment verification..."
    log "INFO" "(Checks run in order; the first failure stops verification and dumps cluster state.)"
    log "INFO" "================================================================================"

    local step
    for step in "$@"; do
        verify_invoke "$step" || break
    done

    log "INFO" "================================================================================"
    log "INFO" "Verification summary:"
    _verify_print_summary "$@"
    if [[ ${#VERIFY_FAILED_STEPS[@]} -eq 0 ]]; then
        log "INFO" "================================================================================"
        return 0
    fi

    log "ERROR" "${#VERIFY_FAILED_STEPS[@]} verification check(s) FAILED"
    log "INFO" "================================================================================"
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
        verify-zt-deployment) verify_zt_deployment ;;
        *)
            echo "Usage: $0 {verify-workers-joined|verify-workers|verify-dpu-nodes|verify-dpu-objects|verify-dpudeployment|verify-deployment|verify-zt-deployment}"
            exit 1
            ;;
    esac
fi
