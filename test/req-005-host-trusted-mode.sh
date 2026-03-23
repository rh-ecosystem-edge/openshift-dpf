#!/usr/bin/env bash
#
# REQ-005: DPF 26.4.X runs in DPF host-trusted mode
#
# Verifies that all DPU objects report dpuInstallInterface: hostAgent,
# which indicates host-trusted mode.

set -eo pipefail

DPF_NAMESPACE="dpf-operator-system"

echo "Checking DPF host-trusted mode..."

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

# 2. Check dpuInstallInterface on each DPU
echo ""
echo "2) Checking dpuInstallInterface on each DPU..."

INTERFACES=$(oc get dpu -n "${DPF_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.dpuInstallInterface}{"\n"}{end}' 2>/dev/null)

NON_HOST_AGENT=0
while IFS=' ' read -r name interface; do
    [[ -z "${name}" ]] && continue
    echo "   ${name}: dpuInstallInterface=${interface}"
    if [[ "${interface}" != "hostAgent" ]]; then
        NON_HOST_AGENT=$((NON_HOST_AGENT + 1))
    fi
done <<< "${INTERFACES}"

if [[ ${NON_HOST_AGENT} -gt 0 ]]; then
    echo ""
    echo "FAIL: ${NON_HOST_AGENT} DPU(s) not using hostAgent (host-trusted mode)"
    exit 1
fi

echo ""
echo "PASS: all ${DPU_COUNT} DPU(s) running in host-trusted mode (dpuInstallInterface=hostAgent)"
