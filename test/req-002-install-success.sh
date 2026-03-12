#!/usr/bin/env bash
#
# REQ-002: DPF 26.4.X can be installed successfully on OCP 4.22.X
#
# Verifies:
# 1. DPFOperatorConfig status version matches 26.4
# 2. OpenShift cluster version matches 4.22
# 3. DPFOperatorConfig reports Ready condition

set -eo pipefail

EXPECTED_DPF_VERSION="26.4"
EXPECTED_OCP_VERSION="4.22"

echo "Checking DPF installation on OCP..."

# 1. DPFOperatorConfig status version
echo ""
echo "1) Checking DPFOperatorConfig status version..."

if ! oc get crd dpfoperatorconfigs.operator.dpu.nvidia.com &>/dev/null; then
    echo "FAIL: DPFOperatorConfig CRD not found — DPF may not be installed"
    exit 1
fi

DPF_VERSION=$(oc get dpfoperatorconfigs.operator.dpu.nvidia.com -A -o jsonpath='{.items[0].status.version}' 2>/dev/null || true)
if [[ -z "${DPF_VERSION}" ]]; then
    echo "FAIL: could not retrieve DPFOperatorConfig status version"
    exit 1
fi

if [[ "${DPF_VERSION}" != ${EXPECTED_DPF_VERSION}* ]]; then
    echo "FAIL: DPFOperatorConfig version '${DPF_VERSION}' does not match expected '${EXPECTED_DPF_VERSION}.X'"
    exit 1
fi
echo "   DPFOperatorConfig version: ${DPF_VERSION}"

# 2. OpenShift cluster version
echo ""
echo "2) Checking OpenShift cluster version..."

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
if [[ -z "${OCP_VERSION}" ]]; then
    echo "FAIL: could not retrieve OpenShift cluster version"
    exit 1
fi

if [[ "${OCP_VERSION}" != ${EXPECTED_OCP_VERSION}* ]]; then
    echo "FAIL: OpenShift version '${OCP_VERSION}' does not match expected '${EXPECTED_OCP_VERSION}.X'"
    exit 1
fi
echo "   OpenShift cluster version: ${OCP_VERSION}"

# 3. DPFOperatorConfig Ready condition
echo ""
echo "3) Checking DPFOperatorConfig Ready condition..."

READY_STATUS=$(oc get dpfoperatorconfigs.operator.dpu.nvidia.com -A \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

if [[ "${READY_STATUS}" != "True" ]]; then
    echo "FAIL: DPFOperatorConfig is not Ready (status: '${READY_STATUS}')"
    oc get dpfoperatorconfigs.operator.dpu.nvidia.com -A -o jsonpath='{.items[0].status.conditions}' 2>/dev/null | jq . 2>/dev/null || true
    exit 1
fi
echo "   DPFOperatorConfig Ready: True"

echo ""
echo "PASS: DPF ${DPF_VERSION} installed successfully on OCP ${OCP_VERSION}"
