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

    hosted_oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-k8s
  namespace: ${DPF_OPERATOR_NAMESPACE}
rules:
- apiGroups: [""]
  resources: [services, endpoints, pods]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-k8s
  namespace: ${DPF_OPERATOR_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: prometheus-k8s
subjects:
- kind: ServiceAccount
  name: prometheus-k8s
  namespace: openshift-monitoring
---
apiVersion: v1
kind: Service
metadata:
  name: ovs-metrics
  namespace: ${DPF_OPERATOR_NAMESPACE}
  labels:
    app.kubernetes.io/component: ovs-metrics
    app.kubernetes.io/name: ovn-kubernetes
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/component: ovnkube-node
    app.kubernetes.io/name: ovn-kubernetes
  ports:
  - name: ovs-metrics
    port: 9310
    targetPort: 9310
    protocol: TCP
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ovs-metrics
  namespace: ${DPF_OPERATOR_NAMESPACE}
  labels:
    app.kubernetes.io/component: ovs-metrics
    app.kubernetes.io/name: ovn-kubernetes
spec:
  endpoints:
  - port: ovs-metrics
    interval: 30s
  selector:
    matchLabels:
      app.kubernetes.io/component: ovs-metrics
      app.kubernetes.io/name: ovn-kubernetes
  namespaceSelector:
    matchNames:
    - ${DPF_OPERATOR_NAMESPACE}
---
apiVersion: v1
kind: Service
metadata:
  name: ovs-exporter
  namespace: ${DPF_OPERATOR_NAMESPACE}
  labels:
    app.kubernetes.io/component: ovs-exporter
    app.kubernetes.io/name: ovn-kubernetes
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/component: ovnkube-node
    app.kubernetes.io/name: ovn-kubernetes
  ports:
  - name: ovs-exporter
    port: 6103
    targetPort: 6103
    protocol: TCP
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ovs-exporter
  namespace: ${DPF_OPERATOR_NAMESPACE}
  labels:
    app.kubernetes.io/component: ovs-exporter
    app.kubernetes.io/name: ovn-kubernetes
spec:
  endpoints:
  - port: ovs-exporter
    interval: 30s
  selector:
    matchLabels:
      app.kubernetes.io/component: ovs-exporter
      app.kubernetes.io/name: ovn-kubernetes
  namespaceSelector:
    matchNames:
    - ${DPF_OPERATOR_NAMESPACE}
EOF

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

    local node_a="${nodes[0]}"
    local node_b="${nodes[1]}"
    log "INFO" "Using nodes: ${node_a} (iperf-a) and ${node_b} (iperf-b)"

    check_namespace_exists "${IPERF_NAMESPACE}" || oc create namespace "${IPERF_NAMESPACE}"

    oc adm policy add-scc-to-user anyuid -z default -n "${IPERF_NAMESPACE}" 2>/dev/null || true

    oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: iperf-a
  namespace: ${IPERF_NAMESPACE}
spec:
  selector:
    app: iperf
    role: a
  ports:
  - port: 5201
    targetPort: 5201
---
apiVersion: v1
kind: Service
metadata:
  name: iperf-b
  namespace: ${IPERF_NAMESPACE}
spec:
  selector:
    app: iperf
    role: b
  ports:
  - port: 5201
    targetPort: 5201
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iperf-a
  namespace: ${IPERF_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: iperf
      role: a
  template:
    metadata:
      labels:
        app: iperf
        role: a
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${node_a}
      containers:
      - name: server
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["/bin/sh", "-c"]
        args:
        - microdnf install -y iperf3 && exec iperf3 -s -p 5201
        ports:
        - containerPort: 5201
      - name: client
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          microdnf install -y iperf3
          echo "Waiting for iperf-b service..."
          until iperf3 -c iperf-b.${IPERF_NAMESPACE}.svc -p 5201 -t 1 >/dev/null 2>&1; do
            sleep 5
          done
          echo "iperf-b reachable, starting continuous bidir traffic"
          while true; do
            iperf3 -c iperf-b.${IPERF_NAMESPACE}.svc -p 5201 --bidir -t 3600
            sleep 1
          done
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iperf-b
  namespace: ${IPERF_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: iperf
      role: b
  template:
    metadata:
      labels:
        app: iperf
        role: b
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${node_b}
      containers:
      - name: server
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["/bin/sh", "-c"]
        args:
        - microdnf install -y iperf3 && exec iperf3 -s -p 5201
        ports:
        - containerPort: 5201
      - name: client
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          microdnf install -y iperf3
          echo "Waiting for iperf-a service..."
          until iperf3 -c iperf-a.${IPERF_NAMESPACE}.svc -p 5201 -t 1 >/dev/null 2>&1; do
            sleep 5
          done
          echo "iperf-a reachable, starting continuous bidir traffic"
          while true; do
            iperf3 -c iperf-a.${IPERF_NAMESPACE}.svc -p 5201 --bidir -t 3600
            sleep 1
          done
EOF

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
STRESS_PROFILES_DIR="${SCRIPT_DIR}/../manifests/stress"
OPENSEARCH_URL="${OPENSEARCH_URL:-}"
STRESS_PODS_PER_NODE="${STRESS_PODS_PER_NODE:-64}"
STRESS_CHURN_DURATION="${STRESS_CHURN_DURATION:-${STRESS_DURATION}}"
STRESS_CHURN_PERCENT="${STRESS_CHURN_PERCENT:-50}"
STRESS_CHURN_DELAY="${STRESS_CHURN_DELAY:-2m}"
STRESS_SELECTOR="${STRESS_SELECTOR:-node-role.kubernetes.io/worker-dpu=}"

ensure_thanos_nodeport() {
    log "INFO" "Ensuring thanos-querier NodePort service exists on the hosted cluster" >&2
    if hosted_oc get svc thanos-querier-nodeport -n openshift-monitoring &>/dev/null; then
        log "INFO" "thanos-querier-nodeport already exists" >&2
    else
        log "INFO" "Creating thanos-querier-nodeport service" >&2
        hosted_oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: thanos-querier-nodeport
  namespace: openshift-monitoring
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: thanos-query
  ports:
  - name: https
    port: 9091
    targetPort: https
    protocol: TCP
EOF
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
    local mgmt_token="$1"
    local hosted_token="$2"
    local hosted_endpoint="$3"
    local output_file="$4"

    local mgmt_endpoint="https://prometheus-k8s-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

    if [[ -z "${OPENSEARCH_URL}" ]]; then
        log "ERROR" "OPENSEARCH_URL is not set. Set it in .env or export it before running."
        log "ERROR" "Format: https://user:password@opensearch-host:port"
        return 1
    fi

    cat > "${output_file}" <<EOF
# Management cluster Prometheus (alerts + metrics collection)
- endpoint: ${mgmt_endpoint}
  token: ${mgmt_token}
  skipTLSVerify: true
  metrics:
    - ${STRESS_PROFILES_DIR}/metrics-report.yml
  alerts:
    - ${STRESS_PROFILES_DIR}/alerts.yml
  indexer:
    esServers: ["${OPENSEARCH_URL}"]
    insecureSkipVerify: true
    defaultIndex: kube-burner-ocp-mgmt
    type: opensearch

# Hosted cluster thanos-querier via NodePort (metrics + alerts)
- endpoint: ${hosted_endpoint}
  token: ${hosted_token}
  skipTLSVerify: true
  metrics:
    - ${STRESS_PROFILES_DIR}/metrics-report-hosted.yml
  alerts:
    - ${STRESS_PROFILES_DIR}/alerts.yml
  indexer:
    esServers: ["${OPENSEARCH_URL}"]
    insecureSkipVerify: true
    defaultIndex: kube-burner-ocp-hosted
    type: opensearch
EOF

    log "INFO" "Generated metrics-endpoint file: ${output_file}"
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
    local hosted_endpoint="https://${node_ip}:${nodeport}"
    log "INFO" "Hosted Prometheus endpoint: ${hosted_endpoint}"

    # Safety window: churn duration + 24h for pod creation/teardown, metrics indexing, and token validity
    local churn_hours
    churn_hours=$(duration_to_hours "${STRESS_CHURN_DURATION}")
    local safety_hours=$(( churn_hours + 24 ))
    if [[ ${safety_hours} -lt 25 ]]; then
        safety_hours=25
    fi
    local safety_window="${safety_hours}h"

    local tokens
    tokens=$(generate_tokens "${safety_window}")
    local mgmt_token hosted_token
    mgmt_token=$(echo "${tokens}" | cut -d' ' -f1)
    hosted_token=$(echo "${tokens}" | cut -d' ' -f2)

    if [[ -z "${mgmt_token}" || -z "${hosted_token}" ]]; then
        log "ERROR" "Failed to generate one or both tokens"
        return 1
    fi
    log "INFO" "Tokens and timeout window: ${safety_window} (churn duration + 24h)"

    # Generate metrics-endpoint.yaml
    local metrics_endpoint_file
    metrics_endpoint_file="${SCRIPT_DIR}/../manifests/generated/metrics-endpoint.yaml"
    mkdir -p "$(dirname "${metrics_endpoint_file}")"
    generate_metrics_endpoint "${mgmt_token}" "${hosted_token}" "${hosted_endpoint}" "${metrics_endpoint_file}"

    # Run kube-burner-ocp
    log "INFO" "Running kube-burner-ocp node-density-cni"
    log "INFO" "  Duration: ${STRESS_DURATION}"
    log "INFO" "  Pods per node: ${STRESS_PODS_PER_NODE}"
    log "INFO" "  Churn duration: ${STRESS_CHURN_DURATION}"
    log "INFO" "  Churn percent: ${STRESS_CHURN_PERCENT}%"
    log "INFO" "  Churn delay: ${STRESS_CHURN_DELAY}"
    log "INFO" "  Selector: ${STRESS_SELECTOR}"
    log "INFO" "  Timeout: ${safety_window}"

    kube-burner-ocp node-density-cni \
        --pods-per-node="${STRESS_PODS_PER_NODE}" \
        --selector="${STRESS_SELECTOR}" \
        --churn-duration="${STRESS_CHURN_DURATION}" \
        --churn-percent="${STRESS_CHURN_PERCENT}" \
        --churn-delay="${STRESS_CHURN_DELAY}" \
        --timeout="${safety_window}" \
        --metrics-endpoint="${metrics_endpoint_file}"

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
