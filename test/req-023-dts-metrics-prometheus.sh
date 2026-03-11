#!/usr/bin/env bash
#
# REQ-023: The DTS DPUService exposes metrics to the end user through Prometheus
#
# Verifies DTS metrics are actually present in the OpenShift Prometheus by
# querying Thanos Querier for doca_telemetry metrics.

set -eo pipefail

DPF_NAMESPACE="dpf-operator-system"
MONITORING_NS="openshift-monitoring"
SA_NAME="dpf-metrics-check"

echo "Checking DTS metrics in Prometheus..."

# 1. Get Thanos Querier route
echo ""
echo "1) Finding Thanos Querier route..."

THANOS_HOST=$(oc get route thanos-querier -n "${MONITORING_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -z "${THANOS_HOST}" ]]; then
    echo "FAIL: thanos-querier route not found in ${MONITORING_NS}"
    exit 1
fi
echo "   Thanos Querier: ${THANOS_HOST}"

# 2. Create a temporary ServiceAccount with cluster-monitoring-view and get a token
echo ""
echo "2) Creating temporary ServiceAccount for monitoring access..."

oc create serviceaccount "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true

TOKEN=$(oc create token "${SA_NAME}" -n "${DPF_NAMESPACE}" --duration=120s 2>/dev/null || true)

if [[ -z "${TOKEN}" ]]; then
    echo "FAIL: could not create a token for ServiceAccount ${SA_NAME}"
    oc delete serviceaccount "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true
    exit 1
fi

# 3. Query Prometheus for DTS metrics
echo ""
echo "3) Querying Prometheus for DTS metrics..."

cleanup() {
    oc delete serviceaccount "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true
    oc adm policy remove-cluster-role-from-user cluster-monitoring-view -z "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true
}
trap cleanup EXIT

QUERY='count({__name__=~"doca_telemetry.*"})'
RESPONSE=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
    "https://${THANOS_HOST}/api/v1/query?query=${QUERY}" 2>/dev/null || true)

if [[ -z "${RESPONSE}" ]]; then
    echo "FAIL: no response from Thanos Querier"
    exit 1
fi

STATUS=$(echo "${RESPONSE}" | jq -r '.status' 2>/dev/null || true)
if [[ "${STATUS}" != "success" ]]; then
    echo "FAIL: Prometheus query failed"
    echo "${RESPONSE}" | jq . 2>/dev/null || echo "${RESPONSE}"
    exit 1
fi

METRIC_COUNT=$(echo "${RESPONSE}" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "0")

echo "   Query: ${QUERY}"
echo "   Matching time series: ${METRIC_COUNT}"

if [[ "${METRIC_COUNT}" == "0" || "${METRIC_COUNT}" == "null" ]]; then
    echo ""
    echo "   No doca_telemetry metrics found, trying broader search..."

    QUERY_BROAD='{__name__=~"doca.*|dts.*"}'
    RESPONSE_BROAD=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
        "https://${THANOS_HOST}/api/v1/query?query=${QUERY_BROAD}" 2>/dev/null || true)

    BROAD_COUNT=$(echo "${RESPONSE_BROAD}" | jq -r '.data.result | length' 2>/dev/null || echo "0")
    echo "   Broader query (doca.*|dts.*) matches: ${BROAD_COUNT}"

    if [[ "${BROAD_COUNT}" == "0" || "${BROAD_COUNT}" == "null" ]]; then
        echo ""
        echo "FAIL: no DTS-related metrics found in Prometheus"
        exit 1
    fi

    echo ""
    echo "   Sample metric names:"
    echo "${RESPONSE_BROAD}" | jq -r '.data.result[].metric.__name__' 2>/dev/null | sort -u | head -5 | sed 's/^/     /'
fi

echo ""
echo "PASS: DTS metrics are present in Prometheus (${METRIC_COUNT} time series)"
