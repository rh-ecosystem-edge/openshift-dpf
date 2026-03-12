#!/usr/bin/env bash
#
# REQ-007: DPF 26.4.X operates a cluster with a mix of DPU workers and non-DPU workers
#
# Verifies that the cluster has both DPU-equipped and non-DPU worker nodes.

set -eo pipefail

echo "Checking for mix of DPU and non-DPU worker nodes..."

WORKER_NODES=$(oc get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null)
if [[ -z "${WORKER_NODES}" ]]; then
    WORKER_NODES=$(oc get nodes -l '!node-role.kubernetes.io/master' --no-headers 2>/dev/null)
fi

WORKER_COUNT=$(echo "${WORKER_NODES}" | grep -c . || true)
if [[ "${WORKER_COUNT}" -eq 0 ]]; then
    echo "FAIL: no worker nodes found"
    exit 1
fi

if ! oc get crd dpus.provisioning.dpu.nvidia.com &>/dev/null; then
    echo "FAIL: DPU CRD not found — cannot determine DPU-equipped nodes"
    exit 1
fi

DPU_HOSTS=$(oc get dpus.provisioning.dpu.nvidia.com -A -o jsonpath='{.items[*].spec.nodeEffect.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u)
DPU_HOST_COUNT=$(echo "${DPU_HOSTS}" | grep -c . || true)

NON_DPU_COUNT=$((WORKER_COUNT - DPU_HOST_COUNT))

if [[ "${DPU_HOST_COUNT}" -eq 0 ]]; then
    echo "FAIL: no DPU-equipped worker nodes found (${WORKER_COUNT} workers, 0 with DPUs)"
    exit 1
fi

if [[ "${NON_DPU_COUNT}" -le 0 ]]; then
    echo "FAIL: no non-DPU worker nodes found (${WORKER_COUNT} workers, all with DPUs)"
    exit 1
fi

echo "PASS: cluster has ${DPU_HOST_COUNT} DPU worker(s) and ${NON_DPU_COUNT} non-DPU worker(s)"
oc get nodes -l '!node-role.kubernetes.io/control-plane' -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels.node-role\\.kubernetes\\.io
