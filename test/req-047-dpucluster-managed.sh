#!/usr/bin/env bash
#
# REQ-047: DPUCluster does not require direct interaction with HyperShift by the user
#
# Verifies the HostedCluster is managed by DPF (not created manually) by
# checking that its managedFields include hypershift-controlplane-manager.

set -eo pipefail

CLUSTERS_NAMESPACE="${CLUSTERS_NAMESPACE:-clusters}"
HOSTED_CLUSTER_NAME="${HOSTED_CLUSTER_NAME:-}"

echo "Checking that DPUCluster is managed via DPF (not direct HyperShift interaction)..."

# 1. Find HostedCluster
echo ""
echo "1) Looking for HostedCluster..."

if [[ -n "${HOSTED_CLUSTER_NAME}" ]]; then
    HC_NAME="${HOSTED_CLUSTER_NAME}"
    HC_NS="${CLUSTERS_NAMESPACE}"
else
    HC_LINE=$(oc get hostedclusters -A --no-headers 2>/dev/null | head -1)
    if [[ -z "${HC_LINE}" ]]; then
        echo "FAIL: no HostedCluster found"
        exit 1
    fi
    HC_NS=$(echo "${HC_LINE}" | awk '{print $1}')
    HC_NAME=$(echo "${HC_LINE}" | awk '{print $2}')
fi

echo "   HostedCluster: ${HC_NAME} (namespace: ${HC_NS})"

# 2. Check managedFields for hypershift-controlplane-manager
echo ""
echo "2) Checking managedFields for hypershift-controlplane-manager..."

MANAGERS=$(oc get hostedcluster -n "${HC_NS}" "${HC_NAME}" \
    -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null || true)

echo "   Managers found: ${MANAGERS}"

if echo "${MANAGERS}" | grep -q "hypershift-controlplane-manager"; then
    echo ""
    echo "PASS: HostedCluster '${HC_NAME}' is managed by hypershift-controlplane-manager"
    exit 0
fi

echo ""
echo "FAIL: hypershift-controlplane-manager not found in managedFields"
echo "   This suggests the HostedCluster may have been created manually"
exit 1
