#!/usr/bin/env bash
#
# REQ-013: A DPUDeployment can deploy DPUServices
#
# Verifies:
# 1. At least one DPUService exists in dpf-operator-system
# 2. At least one DPUService is Ready

set -eo pipefail

DPF_NAMESPACE="dpf-operator-system"

echo "Checking that DPUServices have been deployed..."

# 1. Check DPUService objects exist
echo ""
echo "1) Checking for DPUService objects in ${DPF_NAMESPACE}..."

SVC_OUTPUT=$(oc get dpuservice -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null || true)
if [[ -z "${SVC_OUTPUT}" ]]; then
    echo "FAIL: no DPUService objects found in namespace ${DPF_NAMESPACE}"
    exit 1
fi

SVC_COUNT=$(echo "${SVC_OUTPUT}" | wc -l | tr -d ' ')
echo "   Found ${SVC_COUNT} DPUService object(s)"
echo ""
oc get dpuservice -n "${DPF_NAMESPACE}"

# 2. Check at least one DPUService is Ready
echo ""
echo "2) Checking DPUService Ready status..."

READY_COUNT=$(oc get dpuservice -n "${DPF_NAMESPACE}" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c "True" || true)

if [[ "${READY_COUNT}" -eq 0 ]]; then
    echo "FAIL: no DPUServices are in Ready state"
    exit 1
fi

echo "PASS: ${READY_COUNT}/${SVC_COUNT} DPUService(s) deployed and Ready"
