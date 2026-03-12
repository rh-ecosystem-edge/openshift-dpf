#!/usr/bin/env bash
#
# REQ-049: OpenShift cluster has 3 control plane nodes
#
# Verifies that exactly 3 control plane nodes exist and are Ready.

set -eo pipefail

echo "Checking control plane node count..."

CP_NODES=$(oc get nodes -l node-role.kubernetes.io/control-plane= --no-headers 2>/dev/null || true)
if [[ -z "${CP_NODES}" ]]; then
    CP_NODES=$(oc get nodes -l node-role.kubernetes.io/master= --no-headers 2>/dev/null || true)
fi

if [[ -z "${CP_NODES}" ]]; then
    echo "FAIL: no control plane nodes found"
    exit 1
fi

CP_COUNT=$(echo "${CP_NODES}" | wc -l | tr -d ' ')
if [[ "${CP_COUNT}" -ne 3 ]]; then
    echo "FAIL: expected 3 control plane nodes, found ${CP_COUNT}"
    echo "${CP_NODES}"
    exit 1
fi

READY_COUNT=$(echo "${CP_NODES}" | grep -c " Ready " || true)
if [[ "${READY_COUNT}" -ne 3 ]]; then
    echo "FAIL: expected 3 Ready control plane nodes, found ${READY_COUNT}"
    echo "${CP_NODES}"
    exit 1
fi

echo "PASS: 3 control plane nodes found, all Ready"
echo "${CP_NODES}"
