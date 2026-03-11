#!/usr/bin/env bash
#
# REQ-022: The DTS DPUService reports metrics to a Prometheus endpoint available on the DPU
#
# Verifies:
# 1. A doca-telemetry-service Service exists in dpf-operator-system
# 2. The service has endpoints
# 3. The /metrics endpoint returns Prometheus-format metrics

set -eo pipefail

DPF_NAMESPACE="dpf-operator-system"

echo "Checking DTS metrics endpoint..."

# 1. Find the doca-telemetry-service
echo ""
echo "1) Looking for doca-telemetry-service in ${DPF_NAMESPACE}..."

DTS_SVC=$(oc get svc -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null \
    | awk '{print $1}' | grep "^doca-telemetry-service" | head -1 || true)

if [[ -z "${DTS_SVC}" ]]; then
    echo "FAIL: no doca-telemetry-service found in namespace ${DPF_NAMESPACE}"
    oc get svc -n "${DPF_NAMESPACE}" 2>/dev/null || true
    exit 1
fi

echo "   Found service: ${DTS_SVC}"

# 2. Get endpoints
echo ""
echo "2) Getting service endpoints..."

ENDPOINTS=$(oc get endpointslice -n "${DPF_NAMESPACE}" -l "kubernetes.io/service-name=${DTS_SVC}" \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" "}{end}' 2>/dev/null || true)

if [[ -z "${ENDPOINTS}" ]]; then
    ENDPOINTS=$(oc get endpoints -n "${DPF_NAMESPACE}" "${DTS_SVC}" \
        -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || true)
fi

if [[ -z "${ENDPOINTS}" ]]; then
    echo "FAIL: no endpoints found for ${DTS_SVC}"
    exit 1
fi

PORT=$(oc get svc -n "${DPF_NAMESPACE}" "${DTS_SVC}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)
if [[ -z "${PORT}" ]]; then
    PORT=$(oc get endpoints -n "${DPF_NAMESPACE}" "${DTS_SVC}" \
        -o jsonpath='{.subsets[0].ports[0].port}' 2>/dev/null || true)
fi

ENDPOINT_IP=$(echo "${ENDPOINTS}" | awk '{print $1}')
echo "   Endpoint: ${ENDPOINT_IP}:${PORT}"

# 3. Curl the /metrics endpoint
echo ""
echo "3) Querying /metrics endpoint at ${ENDPOINT_IP}:${PORT}..."

METRICS_OUTPUT=$(curl -s --max-time 10 "http://${ENDPOINT_IP}:${PORT}/metrics" 2>/dev/null || true)

if [[ -z "${METRICS_OUTPUT}" ]]; then
    echo "FAIL: /metrics endpoint returned empty response"
    exit 1
fi

if echo "${METRICS_OUTPUT}" | grep -qE '^# (HELP|TYPE) '; then
    METRIC_COUNT=$(echo "${METRICS_OUTPUT}" | grep -c '^# HELP ' || true)
    echo "   Received Prometheus metrics (${METRIC_COUNT} metric families)"
    echo ""
    echo "   Sample metrics:"
    echo "${METRICS_OUTPUT}" | grep '^# HELP ' | head -5 | sed 's/^/     /'
    echo ""
    echo "PASS: DTS metrics endpoint is serving Prometheus-format metrics"
else
    echo "FAIL: /metrics response does not contain Prometheus-format metrics"
    echo "${METRICS_OUTPUT}" | head -10
    exit 1
fi
