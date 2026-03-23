#!/usr/bin/env bash
#
# REQ-009: A DPUDeployment can provision DPUs
#
# Basic validation that DPUs have been provisioned:
# 1. DPU objects exist in the dpf-operator-system namespace
# 2. At least one DPU is in Ready state

set -eo pipefail

DPF_NAMESPACE="dpf-operator-system"

echo "Checking that DPUs have been provisioned..."

# 1. Check DPU objects exist
echo ""
echo "1) Checking for DPU objects in ${DPF_NAMESPACE}..."

DPU_OUTPUT=$(oc get dpu -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null || true)
if [[ -z "${DPU_OUTPUT}" ]]; then
    echo "FAIL: no DPU objects found in namespace ${DPF_NAMESPACE}"
    exit 1
fi

DPU_COUNT=$(echo "${DPU_OUTPUT}" | wc -l | tr -d ' ')
echo "   Found ${DPU_COUNT} DPU object(s)"
echo ""
oc get dpu -n "${DPF_NAMESPACE}"

# 2. Check at least one DPU is Ready
echo ""
echo "2) Checking DPU Ready status..."

READY_COUNT=$(oc get dpu -n "${DPF_NAMESPACE}" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c "True" || true)

if [[ "${READY_COUNT}" -eq 0 ]]; then
    echo "FAIL: no DPUs are in Ready state"
    oc get dpu -n "${DPF_NAMESPACE}" -o custom-columns=NAME:.metadata.name,READY:.status.conditions[*].status
    exit 1
fi

echo "PASS: ${READY_COUNT}/${DPU_COUNT} DPU(s) are provisioned and Ready"
