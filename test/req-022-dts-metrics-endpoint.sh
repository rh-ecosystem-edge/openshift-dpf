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

METRICS_TMP=$(mktemp)
curl -s --max-time 30 "http://${ENDPOINT_IP}:${PORT}/metrics" > "${METRICS_TMP}" 2>/dev/null || true

if [[ ! -s "${METRICS_TMP}" ]]; then
    echo "FAIL: /metrics endpoint returned empty response"
    rm -f "${METRICS_TMP}"
    exit 1
fi

LINE_COUNT=$(wc -l < "${METRICS_TMP}" | tr -d ' ')
echo "   Received ${LINE_COUNT} lines"

EXPECTED_METRICS="rx_packets rx_bytes tx_packets tx_bytes"
FOUND=0
MISSING=""

for metric in ${EXPECTED_METRICS}; do
    if grep -q "TYPE ${metric} " "${METRICS_TMP}"; then
        FOUND=$((FOUND + 1))
        echo "   Found: ${metric}"
    else
        MISSING="${MISSING} ${metric}"
    fi
done

rm -f "${METRICS_TMP}"

if [[ ${FOUND} -eq 0 ]]; then
    echo "FAIL: none of the expected DTS metrics found (${EXPECTED_METRICS})"
    echo ""
    echo "   First 10 lines of response:"
    echo "${METRICS_OUTPUT}" | head -10 | sed 's/^/     /'
    exit 1
fi

if [[ -n "${MISSING}" ]]; then
    echo "   Missing:${MISSING}"
fi

echo ""
echo "PASS: DTS metrics endpoint reports ${FOUND}/$(echo ${EXPECTED_METRICS} | wc -w | tr -d ' ') expected metrics"
