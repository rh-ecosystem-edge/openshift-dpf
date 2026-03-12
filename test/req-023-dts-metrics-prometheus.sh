#!/usr/bin/env bash
#
# REQ-023: The DTS DPUService exposes metrics to the end user through Prometheus
#
# Verifies DTS metrics are actually present in the OpenShift Prometheus by
# querying Thanos Querier for rx_packets / tx_packets metrics.

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
echo "2) Setting up monitoring access..."

cleanup() {
    oc delete secret "${SA_NAME}-token" -n "${DPF_NAMESPACE}" 2>/dev/null || true
    oc delete serviceaccount "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true
    oc adm policy remove-cluster-role-from-user cluster-monitoring-view -z "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true
}
trap cleanup EXIT

oc create serviceaccount "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z "${SA_NAME}" -n "${DPF_NAMESPACE}" 2>/dev/null || true

# Try oc create token first, fall back to secret-based token
TOKEN=$(oc create token "${SA_NAME}" -n "${DPF_NAMESPACE}" --duration=120s 2>/dev/null || true)

if [[ -z "${TOKEN}" ]]; then
    echo "   oc create token not available, using secret-based token..."
    oc apply -f - <<EOF 2>/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-token
  namespace: ${DPF_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF
    sleep 3
    TOKEN=$(oc get secret "${SA_NAME}-token" -n "${DPF_NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
fi

if [[ -z "${TOKEN}" ]]; then
    echo "FAIL: could not obtain a token for ServiceAccount ${SA_NAME}"
    exit 1
fi
echo "   Token obtained"

# 3. Query Prometheus for DTS metrics
echo ""
echo "3) Querying Prometheus for DTS metrics..."

QUERY='count(rx_packets) or count(rx_bytes) or count(tx_packets) or count(tx_bytes)'
RESPONSE=$(curl -sk -G -H "Authorization: Bearer ${TOKEN}" \
    "https://${THANOS_HOST}/api/v1/query" \
    --data-urlencode "query=${QUERY}" 2>/dev/null || true)

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
    echo "FAIL: no DTS metrics (rx_packets, rx_bytes, tx_packets, tx_bytes) found in Prometheus"
    exit 1
fi

echo ""
echo "   Verifying individual metrics..."
for metric in rx_packets rx_bytes tx_packets tx_bytes; do
    COUNT=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
        "https://${THANOS_HOST}/api/v1/query?query=count(${metric})" 2>/dev/null \
        | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "0")
    echo "   ${metric}: ${COUNT} series"
done

echo ""
echo "PASS: DTS metrics are present in Prometheus"
