#!/usr/bin/env bash
#
# REQ-019: The DTS DPUService can be installed
#
# Verifies:
# 1. A DPUService containing "dts" exists in dpf-operator-system
# 2. The DTS DPUService is Ready

set -eo pipefail

DPF_NAMESPACE="dpf-operator-system"

echo "Checking DTS DPUService installation..."

# 1. Find DTS DPUService
echo ""
echo "1) Looking for DTS DPUService in ${DPF_NAMESPACE}..."

DTS_SERVICES=$(oc get dpuservice -n "${DPF_NAMESPACE}" --no-headers 2>/dev/null | grep -i  doca-telemetry-service || true)
if [[ -z "${DTS_SERVICES}" ]]; then
    echo "FAIL: no DTS DPUService found in namespace ${DPF_NAMESPACE}"
    oc get dpuservice -n "${DPF_NAMESPACE}" 2>/dev/null || true
    exit 1
fi

DTS_NAME=$(echo "${DTS_SERVICES}" | head -1 | awk '{print $1}')
echo "   Found DTS DPUService: ${DTS_NAME}"

# 2. Check Ready condition
echo ""
echo "2) Checking DTS DPUService Ready status..."

READY_STATUS=$(oc get dpuservice -n "${DPF_NAMESPACE}" "${DTS_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

if [[ "${READY_STATUS}" != "True" ]]; then
    echo "FAIL: DTS DPUService '${DTS_NAME}' is not Ready (status: '${READY_STATUS}')"
    oc get dpuservice -n "${DPF_NAMESPACE}" "${DTS_NAME}" -o jsonpath='{.status.conditions}' 2>/dev/null | jq . 2>/dev/null || true
    exit 1
fi

echo "PASS: DTS DPUService '${DTS_NAME}' is installed and Ready"
