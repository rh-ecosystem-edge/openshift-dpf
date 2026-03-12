#!/usr/bin/env bash
#
# REQ-006: DPF 26.4.X detects DPUs on worker nodes automatically
#
# Verifies that DPU objects have been created for worker nodes with DPUs.
# Checks that DPUSet or DPU custom resources exist in the cluster.

set -eo pipefail

echo "Checking for automatic DPU detection..."

if ! oc get crd dpus.provisioning.dpu.nvidia.com &>/dev/null; then
    echo "FAIL: DPU CRD (dpus.provisioning.dpu.nvidia.com) not found — DPF may not be installed"
    exit 1
fi

DPU_COUNT=$(oc get dpus.provisioning.dpu.nvidia.com -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${DPU_COUNT}" -eq 0 ]]; then
    echo "FAIL: no DPU objects found — DPUs may not have been detected"
    exit 1
fi

echo "PASS: ${DPU_COUNT} DPU object(s) detected"
oc get dpus.provisioning.dpu.nvidia.com -A
