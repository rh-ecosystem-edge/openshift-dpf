#!/bin/bash
#
# Deploy a squid proxy for the cluster and produce a kubeconfig with
# the ingress CA appended. Run on the hypervisor via 'make deploy-proxy'.
#
# Requires: KUBECONFIG

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROXY_PORT=8213
KUBECONFIG_DIR="$(cd "$(dirname "${KUBECONFIG}")" && pwd)"
OUTPUT_KUBECONFIG="${OUTPUT_KUBECONFIG:-kubeconfig.proxy}"

deploy_proxy() {
	CLUSTER_DOMAIN="$(oc config view --minify \
		-o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https://api\.([^:]+):.*#\1#')"

	SQUID_CONF="${KUBECONFIG_DIR}/dpf-ci-squid.conf"
	sed -e "s/\${CLUSTER_DOMAIN}/${CLUSTER_DOMAIN}/g" \
		-e "s/\${PROXY_PORT}/${PROXY_PORT}/g" \
		"${SCRIPT_DIR}/squid.conf.template" >"${SQUID_CONF}"

	bash "${SCRIPT_DIR}/start-squid.sh" "${SQUID_CONF}"

	echo "Squid proxy listening on :${PROXY_PORT} for *.${CLUSTER_DOMAIN}"
}

append_ingress_ca() {
	cp "${KUBECONFIG}" "${OUTPUT_KUBECONFIG}"

	CLUSTER_CTX="$(KUBECONFIG="${OUTPUT_KUBECONFIG}" oc config view --minify -o jsonpath='{.clusters[0].name}')"

	CA_TMPDIR="$(mktemp -d)"
	trap 'rm -rf "${CA_TMPDIR}"' EXIT

	oc get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.tls\.crt}' | base64 -d >"${CA_TMPDIR}/ingress-ca.crt"
	oc config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"${CA_TMPDIR}/existing-cas.pem"

	cat "${CA_TMPDIR}/existing-cas.pem" "${CA_TMPDIR}/ingress-ca.crt" >"${CA_TMPDIR}/combined-cas.pem"

	KUBECONFIG="${OUTPUT_KUBECONFIG}" oc config set "clusters.${CLUSTER_CTX}.certificate-authority-data" "$(base64 -w0 "${CA_TMPDIR}/combined-cas.pem")"
}

deploy_proxy
append_ingress_ca

PROXY_HOST="$(hostname -f 2>/dev/null || hostname)"
OUTPUT_KUBECONFIG_ABS="$(cd "$(dirname "${OUTPUT_KUBECONFIG}")" && pwd)/$(basename "${OUTPUT_KUBECONFIG}")"
echo ""
echo "Kubeconfig with ingress CA: ${OUTPUT_KUBECONFIG_ABS}"
echo ""
echo "To use from a remote machine, copy the kubeconfig and set:"
echo "  export HTTPS_PROXY=http://${PROXY_HOST}:${PROXY_PORT}/"
echo "  export KUBECONFIG=<local path to kubeconfig.proxy>"
