#!/usr/bin/env bash
#
# REQ-001 / REQ-050: DPF on OCP supports amd64 worker and control plane nodes
#
# Verifies that at least one DPU-enabled worker node is amd64.

set -eo pipefail

DPU_LABEL="feature.node.kubernetes.io/dpu-enabled="

echo "Checking for amd64 DPU-enabled worker nodes..."

DPU_NODES=$(oc get nodes -l "${DPU_LABEL}" --no-headers 2>/dev/null || true)
if [[ -z "${DPU_NODES}" ]]; then
    echo "FAIL: no nodes found with label ${DPU_LABEL}"
    exit 1
fi

DPU_ARCHES=$(oc get nodes -l "${DPU_LABEL}" -o jsonpath='{.items[*].status.nodeInfo.architecture}')

for arch in ${DPU_ARCHES}; do
    if [[ "${arch}" == "amd64" ]]; then
        echo "PASS: found amd64 DPU-enabled worker node"
        oc get nodes -l "${DPU_LABEL}" -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture
        exit 0
    fi
done

echo "FAIL: no amd64 DPU-enabled worker nodes found"
oc get nodes -l "${DPU_LABEL}" -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture
exit 1
