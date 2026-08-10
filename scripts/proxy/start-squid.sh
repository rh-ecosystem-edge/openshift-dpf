#!/bin/bash
# Run on the hypervisor to (re)start the squid proxy container.
# Usage: start-squid.sh <path-to-squid.conf>
set -euo pipefail

SQUID_CONF="${1:?Usage: start-squid.sh <path-to-squid.conf>}"

podman rm -f dpf-ci-squid 2>/dev/null || true
podman run -d --net host --name dpf-ci-squid \
	-v "${SQUID_CONF}":/etc/squid/squid.conf:Z \
	-v /etc/resolv.conf:/etc/resolv.conf:ro \
	quay.io/openshifttest/squid-proxy:multiarch
sleep 2
echo "Squid proxy running"
