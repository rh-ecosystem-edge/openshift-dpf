#!/usr/bin/env bash
#
# REQ-034: DPF on OCP can manage 1 DPF managed DPU per worker node
#
# Verifies that every DPU-labeled worker node has at least one DPU object.

set -eo pipefail

DPF_NAMESPACE="dpf-operator-system"
DPU_LABEL="feature.node.kubernetes.io/dpu-enabled="

echo "Checking DPU-per-worker-node mapping..."

# 1. Get DPU-labeled worker nodes
echo ""
echo "1) Finding DPU-enabled worker nodes..."

DPU_NODES=$(oc get nodes -l "${DPU_LABEL}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
if [[ -z "${DPU_NODES}" ]]; then
    echo "FAIL: no nodes found with label ${DPU_LABEL}"
    exit 1
fi

NODE_COUNT=$(echo "${DPU_NODES}" | wc -l | tr -d ' ')
echo "   Found ${NODE_COUNT} DPU-enabled worker node(s)"

# 2. Get DPU objects and their associated node names
echo ""
echo "2) Checking DPU objects in ${DPF_NAMESPACE}..."

DPU_OUTPUT=$(oc get dpu -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null || true)
if [[ -z "${DPU_OUTPUT}" ]]; then
    echo "FAIL: no DPU objects found in namespace ${DPF_NAMESPACE}"
    exit 1
fi

DPU_COUNT=$(echo "${DPU_OUTPUT}" | wc -l | tr -d ' ')
echo "   Found ${DPU_COUNT} DPU object(s)"

# 3. Verify each DPU-labeled node has a corresponding DPU
echo ""
echo "3) Verifying each DPU-enabled node has a managed DPU..."

DPU_NODE_NAMES=$(oc get dpu -n "${DPF_NAMESPACE}" -o jsonpath='{range .items[*]}{.spec.nodeEffect.nodeName}{"\n"}{end}' 2>/dev/null | sort -u)

MISSING=0
while IFS= read -r node; do
    if echo "${DPU_NODE_NAMES}" | grep -q "^${node}$"; then
        echo "   ${node}: DPU found"
    else
        echo "   ${node}: NO DPU found"
        MISSING=$((MISSING + 1))
    fi
done <<< "${DPU_NODES}"

if [[ "${MISSING}" -gt 0 ]]; then
    echo ""
    echo "FAIL: ${MISSING} DPU-enabled node(s) missing a managed DPU"
    exit 1
fi

echo ""
echo "PASS: all ${NODE_COUNT} DPU-enabled worker node(s) have a managed DPU"
