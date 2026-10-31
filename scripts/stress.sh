#!/bin/bash
# stress.sh - Set up OVS memory monitoring and iperf traffic for stress testing
#
# Subcommands:
#   setup   - Configure ovs-exporter, Prometheus scrapers, and iperf traffic (default)
#   verify  - Check monitoring targets and iperf status
#   cleanup - Remove all stress test resources

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

DPF_OPERATOR_NAMESPACE="${DPF_OPERATOR_NAMESPACE:-dpf-operator-system}"
IPERF_NAMESPACE="${IPERF_NAMESPACE:-iperf-test}"
STRESS_PROFILES_DIR="${SCRIPT_DIR}/../manifests/stress"

hosted_oc() {
    oc --kubeconfig="${HOSTED_KUBECONFIG}" "$@"
}

get_dpu_nodes() {
    hosted_oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

get_worker_dpu_nodes() {
    oc get nodes -l node-role.kubernetes.io/worker-dpu -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

setup_ovs_exporter() {
    log "INFO" "Setting up ovs-exporter on DPU nodes"
    local nodes
    read -ra nodes <<< "$(get_dpu_nodes)"

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log "WARN" "No DPU nodes found in hosted cluster, skipping ovs-exporter setup"
        return 0
    fi

    for node in "${nodes[@]}"; do
        log "INFO" "Configuring ovs-exporter on ${node}"
        hosted_oc debug "node/${node}" -- chroot /host sh -c '
            python3 -c "import prometheus_client" 2>/dev/null || pip3 install --quiet prometheus_client
            semanage port -l | grep -q "openvswitch_port_t.*tcp.*6103" || \
                semanage port -a -t openvswitch_port_t -p tcp 6103 2>/dev/null || \
                semanage port -m -t openvswitch_port_t -p tcp 6103
            systemctl reset-failed ovs-exporter 2>/dev/null || true
            systemctl enable --now ovs-exporter
            systemctl is-active ovs-exporter
        ' 2>/dev/null
        log "INFO" "ovs-exporter active on ${node}"
    done
}

setup_prometheus_monitoring() {
    log "INFO" "Setting up Prometheus monitoring for OVS metrics"

    hosted_oc label namespace "${DPF_OPERATOR_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite 2>/dev/null

    export DPF_OPERATOR_NAMESPACE
    envsubst '${DPF_OPERATOR_NAMESPACE}' < "${STRESS_PROFILES_DIR}/prometheus-monitoring.yaml" | hosted_oc apply -f -

    log "INFO" "Prometheus monitoring configured (ports 9310 and 6103)"
}

setup_iperf_traffic() {
    log "INFO" "Setting up iperf traffic generators on management cluster"

    local nodes
    read -ra nodes <<< "$(get_worker_dpu_nodes)"

    if [[ ${#nodes[@]} -lt 2 ]]; then
        log "ERROR" "Need at least 2 worker-dpu nodes, found ${#nodes[@]}"
        return 1
    fi

    export NODE_A="${nodes[0]}"
    export NODE_B="${nodes[1]}"
    export IPERF_NAMESPACE
    log "INFO" "Using nodes: ${NODE_A} (iperf-a) and ${NODE_B} (iperf-b)"

    check_namespace_exists "${IPERF_NAMESPACE}" || oc create namespace "${IPERF_NAMESPACE}"

    oc adm policy add-scc-to-user anyuid -z default -n "${IPERF_NAMESPACE}" 2>/dev/null || true

    envsubst '${NODE_A} ${NODE_B} ${IPERF_NAMESPACE}' < "${STRESS_PROFILES_DIR}/iperf.yaml" | oc apply -f -

    log "INFO" "iperf Deployments created, waiting for pods to start"
    retry 12 10 oc -n "${IPERF_NAMESPACE}" wait --for=condition=Available deployment/iperf-a deployment/iperf-b --timeout=10s
    log "INFO" "iperf traffic generators running"
}

verify_stress() {
    log "INFO" "Verifying stress test setup"

    log "INFO" "Checking Prometheus targets for OVS metrics"
    local targets
    targets=$(hosted_oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
        curl -s --connect-timeout 3 'http://localhost:9090/api/v1/targets' 2>/dev/null | \
        jq '[.data.activeTargets[] | select(.labels.service | test("ovs"))] | length' 2>/dev/null) || targets=0
    log "INFO" "OVS Prometheus targets active: ${targets}"

    log "INFO" "Current ovs-vswitchd memory (port 9310):"
    hosted_oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
        curl -s --connect-timeout 3 'http://localhost:9090/api/v1/query?query=ovs_vswitchd_process_resident_memory_bytes/1024/1024' 2>/dev/null | \
        jq -r '.data.result[] | "  \(.metric.instance): \(.value[1] | tonumber | round) MB"' 2>/dev/null || true

    log "INFO" "Current ovs-vswitchd memory (port 6103):"
    hosted_oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
        curl -s --connect-timeout 3 'http://localhost:9090/api/v1/query?query=ovs_vswitchd_memory_rss/1024/1024' 2>/dev/null | \
        jq -r '.data.result[] | "  \(.metric.instance): \(.value[1] | tonumber | round) MB"' 2>/dev/null || true

    log "INFO" "iperf deployment status:"
    oc get deployments,pods -n "${IPERF_NAMESPACE}" -o wide 2>/dev/null || log "WARN" "No iperf resources found"

    local pod_a
    pod_a=$(oc get pods -n "${IPERF_NAMESPACE}" -l role=a -o name 2>/dev/null | head -1)
    if [[ -n "${pod_a}" ]]; then
        log "INFO" "iperf-a client traffic (last 3 lines):"
        oc logs -n "${IPERF_NAMESPACE}" "${pod_a}" -c client --tail=3 2>/dev/null || true
    fi
}

cleanup_stress() {
    log "INFO" "Cleaning up stress test resources"

    log "INFO" "Removing iperf namespace"
    oc delete namespace "${IPERF_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    log "INFO" "Removing Prometheus monitoring resources"
    hosted_oc delete servicemonitor ovs-metrics ovs-exporter -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    hosted_oc delete svc ovs-metrics ovs-exporter -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    hosted_oc delete rolebinding prometheus-k8s -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    hosted_oc delete role prometheus-k8s -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    hosted_oc label namespace "${DPF_OPERATOR_NAMESPACE}" openshift.io/cluster-monitoring- 2>/dev/null || true
    hosted_oc delete svc thanos-querier-nodeport -n openshift-monitoring --ignore-not-found 2>/dev/null || true

    log "INFO" "Disabling ovs-exporter on DPU nodes"
    local nodes
    read -ra nodes <<< "$(get_dpu_nodes)"
    for node in "${nodes[@]}"; do
        log "INFO" "Disabling ovs-exporter on ${node}"
        hosted_oc debug "node/${node}" -- chroot /host sh -c \
            'systemctl disable --now ovs-exporter 2>/dev/null || true' 2>/dev/null || true
    done

    log "INFO" "Stress test cleanup complete"
}

setup() {
    log "INFO" "Starting stress test setup (monitoring infrastructure)"

    if [[ ! -f "${HOSTED_KUBECONFIG}" ]]; then
        log "ERROR" "Hosted kubeconfig not found: ${HOSTED_KUBECONFIG}"
        return 1
    fi

    setup_ovs_exporter
    setup_prometheus_monitoring

    log "INFO" "Stress test setup complete (monitoring ready)"
}

# ---- kube-burner-ocp stress run ----

STRESS_DURATION="${STRESS_DURATION:-24h}"
OPENSEARCH_URL="${OPENSEARCH_URL:-}"
STRESS_PODS_PER_NODE="${STRESS_PODS_PER_NODE:-64}"
STRESS_CHURN_PERCENT="${STRESS_CHURN_PERCENT:-50}"
STRESS_CHURN_DELAY="${STRESS_CHURN_DELAY:-2m}"
STRESS_SELECTOR="${STRESS_SELECTOR:-node-role.kubernetes.io/worker-dpu=}"

ensure_thanos_nodeport() {
    log "INFO" "Ensuring thanos-querier NodePort service exists on the hosted cluster" >&2
    if hosted_oc get svc thanos-querier-nodeport -n openshift-monitoring &>/dev/null; then
        log "INFO" "thanos-querier-nodeport already exists" >&2
    else
        log "INFO" "Creating thanos-querier-nodeport service" >&2
        hosted_oc apply -f "${STRESS_PROFILES_DIR}/thanos-querier-nodeport.yaml"
    fi

    local nodeport
    nodeport=$(hosted_oc get svc thanos-querier-nodeport -n openshift-monitoring \
        -o jsonpath='{.spec.ports[0].nodePort}')
    log "INFO" "Thanos querier NodePort: ${nodeport}" >&2
    echo "${nodeport}"
}

get_hosted_node_ip() {
    local node_ip
    node_ip=$(hosted_oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    echo "${node_ip}"
}

generate_tokens() {
    local duration_flag="$1"
    log "INFO" "Generating Prometheus tokens (duration: ${duration_flag})" >&2

    local mgmt_token hosted_token
    mgmt_token=$(oc create token prometheus-k8s -n openshift-monitoring \
        --duration="${duration_flag}" 2>/dev/null) || {
        log "ERROR" "Failed to generate management cluster token" >&2
        return 1
    }

    hosted_token=$(hosted_oc create token prometheus-k8s -n openshift-monitoring \
        --duration="${duration_flag}" 2>/dev/null) || {
        log "ERROR" "Failed to generate hosted cluster token" >&2
        return 1
    }

    echo "${mgmt_token}" "${hosted_token}"
}

duration_to_hours() {
    local dur="$1"
    local num="${dur%[hHdDmM]*}"
    local unit="${dur##*[0-9]}"
    case "${unit}" in
        d|D) echo $(( num * 24 )) ;;
        h|H) echo "${num}" ;;
        m|M) echo $(( (num + 59) / 60 )) ;;
        *)   echo "${num}" ;;
    esac
}

generate_metrics_endpoint() {
    local output_file="$1"

    export MGMT_ENDPOINT="https://prometheus-k8s-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
    export MGMT_TOKEN HOSTED_TOKEN HOSTED_ENDPOINT STRESS_PROFILES_DIR

    export METRICS_MGMT="" METRICS_HOSTED="" INDEXER_MGMT="" INDEXER_HOSTED=""
    if [[ -n "${OPENSEARCH_URL}" ]]; then
        METRICS_MGMT="  metrics:
    - ${STRESS_PROFILES_DIR}/metrics-report.yml"
        METRICS_HOSTED="  metrics:
    - ${STRESS_PROFILES_DIR}/metrics-report-hosted.yml"
        INDEXER_MGMT="  indexer:
    esServers: [\"${OPENSEARCH_URL}\"]
    insecureSkipVerify: true
    defaultIndex: kube-burner-ocp-mgmt
    type: opensearch"
        INDEXER_HOSTED="  indexer:
    esServers: [\"${OPENSEARCH_URL}\"]
    insecureSkipVerify: true
    defaultIndex: kube-burner-ocp-hosted
    type: opensearch"
    fi

    umask 077
    envsubst '${MGMT_ENDPOINT} ${MGMT_TOKEN} ${HOSTED_TOKEN} ${HOSTED_ENDPOINT} ${STRESS_PROFILES_DIR} ${METRICS_MGMT} ${METRICS_HOSTED} ${INDEXER_MGMT} ${INDEXER_HOSTED}' \
        < "${STRESS_PROFILES_DIR}/metrics-endpoint.yaml.template" > "${output_file}"

    log "INFO" "Generated metrics-endpoint file: ${output_file}"
}

_run_metrics_file=""
_run_iperf_ns=""

_run_cleanup() {
    [[ -n "${_run_metrics_file}" ]] && rm -f "${_run_metrics_file}"
    log "INFO" "iperf pod status:"
    oc get pods -n "${IPERF_NAMESPACE}" -o wide 2>/dev/null || true
    if [[ -n "${_run_iperf_ns}" ]]; then
        log "INFO" "Cleaning up iperf namespace"
        oc delete namespace "${_run_iperf_ns}" --ignore-not-found 2>/dev/null || true
    else
        log "INFO" "Removing iperf resources"
        oc delete deployment iperf-a iperf-b -n "${IPERF_NAMESPACE}" --ignore-not-found 2>/dev/null || true
        oc delete service iperf-a iperf-b -n "${IPERF_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    fi
}

run_stress() {
    log "INFO" "Starting kube-burner-ocp stress run"

    if ! command -v kube-burner-ocp &>/dev/null; then
        log "ERROR" "kube-burner-ocp not found in PATH. Install it before running."
        return 1
    fi

    if [[ ! -f "${HOSTED_KUBECONFIG}" ]]; then
        log "ERROR" "Hosted kubeconfig not found: ${HOSTED_KUBECONFIG}"
        return 1
    fi

    if [[ -z "${OPENSEARCH_URL}" ]]; then
        log "WARN" "OPENSEARCH_URL is not set; metrics will not be indexed to OpenSearch"
    fi

    # Track iperf namespace ownership: only clean up if this run created it
    if ! oc get namespace "${IPERF_NAMESPACE}" &>/dev/null; then
        _run_iperf_ns="${IPERF_NAMESPACE}"
    fi

    _run_metrics_file="${SCRIPT_DIR}/../manifests/generated/metrics-endpoint.yaml"
    mkdir -p "$(dirname "${_run_metrics_file}")"
    trap _run_cleanup EXIT

    # Start iperf traffic generators
    setup_iperf_traffic

    # Ensure thanos NodePort exists on hosted cluster
    local nodeport
    nodeport=$(ensure_thanos_nodeport)

    local node_ip
    node_ip=$(get_hosted_node_ip)
    if [[ -z "${node_ip}" ]]; then
        log "ERROR" "Could not determine hosted cluster node IP"
        return 1
    fi
    HOSTED_ENDPOINT="https://${node_ip}:${nodeport}"
    log "INFO" "Hosted Prometheus endpoint: ${HOSTED_ENDPOINT}"

    # Safety window: churn duration + 24h for pod creation/teardown, metrics indexing, and token validity
    local churn_hours
    churn_hours=$(duration_to_hours "${STRESS_DURATION}")
    local safety_hours=$(( churn_hours + 24 ))
    if [[ ${safety_hours} -lt 25 ]]; then
        safety_hours=25
    fi
    local safety_window="${safety_hours}h"

    local tokens
    tokens=$(generate_tokens "${safety_window}")
    MGMT_TOKEN=$(echo "${tokens}" | cut -d' ' -f1)
    HOSTED_TOKEN=$(echo "${tokens}" | cut -d' ' -f2)

    if [[ -z "${MGMT_TOKEN}" || -z "${HOSTED_TOKEN}" ]]; then
        log "ERROR" "Failed to generate one or both tokens"
        return 1
    fi
    log "INFO" "Tokens and timeout window: ${safety_window} (churn duration + 24h)"

    # Generate metrics-endpoint.yaml (contains tokens and credentials)
    generate_metrics_endpoint "${_run_metrics_file}"

    # Run kube-burner-ocp
    log "INFO" "Running kube-burner-ocp node-density-cni"
    log "INFO" "  Duration: ${STRESS_DURATION}"
    log "INFO" "  Pods per node: ${STRESS_PODS_PER_NODE}"
    log "INFO" "  Churn percent: ${STRESS_CHURN_PERCENT}%"
    log "INFO" "  Churn delay: ${STRESS_CHURN_DELAY}"
    log "INFO" "  Selector: ${STRESS_SELECTOR}"
    log "INFO" "  Timeout: ${safety_window}"

    kube-burner-ocp node-density-cni \
        --pods-per-node="${STRESS_PODS_PER_NODE}" \
        --selector="${STRESS_SELECTOR}" \
        --churn-duration="${STRESS_DURATION}" \
        --churn-percent="${STRESS_CHURN_PERCENT}" \
        --churn-delay="${STRESS_CHURN_DELAY}" \
        --timeout="${safety_window}" \
        --metrics-endpoint="${_run_metrics_file}"

    log "INFO" "kube-burner-ocp stress run complete"
}

case "${1:-setup}" in
    setup)
        setup
        ;;
    verify)
        verify_stress
        ;;
    cleanup)
        cleanup_stress
        ;;
    run)
        run_stress
        ;;
    *)
        log "ERROR" "Unknown command: ${1}. Use: setup, verify, cleanup, run"
        exit 1
        ;;
esac
