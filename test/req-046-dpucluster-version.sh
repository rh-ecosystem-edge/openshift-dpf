#!/usr/bin/env bash
#
# REQ-046: DPUCluster is a HyperShift cluster based on OpenShift 4.22.X
#
# Verifies:
# 1. A HostedCluster exists
# 2. The DPUCluster reports an OpenShift version starting with 4.22

set -eo pipefail

EXPECTED_OCP_VERSION="4.22"
CLUSTERS_NAMESPACE="${CLUSTERS_NAMESPACE:-clusters}"
HOSTED_CLUSTER_NAME="${HOSTED_CLUSTER_NAME:-}"

echo "Checking DPUCluster OpenShift version..."

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
oc get hostedcluster -n "${HC_NS}" "${HC_NAME}"

# 2. Get DPUCluster kubeconfig and check version
echo ""
echo "2) Fetching DPUCluster kubeconfig and checking version..."

KUBECONFIG_SECRET="${HC_NAME}-admin-kubeconfig"
if ! oc get secret -n "${HC_NS}" "${KUBECONFIG_SECRET}" &>/dev/null; then
    echo "FAIL: kubeconfig secret '${KUBECONFIG_SECRET}' not found in namespace ${HC_NS}"
    exit 1
fi

TMPKUBECONFIG=$(mktemp)
trap "rm -f ${TMPKUBECONFIG}" EXIT
oc get secret -n "${HC_NS}" "${KUBECONFIG_SECRET}" -o jsonpath='{.data.kubeconfig}' | base64 -d > "${TMPKUBECONFIG}"

DPU_CLUSTER_VERSION=$(KUBECONFIG="${TMPKUBECONFIG}" oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)

if [[ -z "${DPU_CLUSTER_VERSION}" ]]; then
    echo "FAIL: could not retrieve DPUCluster OpenShift version"
    exit 1
fi

echo "   DPUCluster OpenShift version: ${DPU_CLUSTER_VERSION}"

if [[ "${DPU_CLUSTER_VERSION}" != ${EXPECTED_OCP_VERSION}* ]]; then
    echo "FAIL: DPUCluster version '${DPU_CLUSTER_VERSION}' does not match expected '${EXPECTED_OCP_VERSION}.X'"
    exit 1
fi

echo ""
echo "PASS: DPUCluster is running OpenShift ${DPU_CLUSTER_VERSION}"
