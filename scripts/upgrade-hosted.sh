#!/bin/bash
# Upgrade a hosted cluster by patching its DPFHCPProvisioner's ocpReleaseImage.
#
# Upgrades the DPFHCPProvisioner identified by UPGRADE_HOSTED_CLUSTER_NAME
# (defaults to HOSTED_CLUSTER_NAME from .env).
#
# Default to z+1 of the currently configured version (e.g. 4.22.2 -> 4.22.3).
# Set HOSTED_UPGRADE_TARGET_VERSION explicitly for a specific version.
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

UPGRADE_HOSTED_CLUSTER_NAME="${UPGRADE_HOSTED_CLUSTER_NAME:-${HOSTED_CLUSTER_NAME}}"
HOSTED_ARCH="multi"

UPGRADE_POLL_INTERVAL=60
UPGRADE_POLL_RETRIES=90

# How long to wait for the operator to start the upgrade after patching
UPGRADE_START_POLL_INTERVAL=10
UPGRADE_START_POLL_RETRIES=30

# How long to wait for the ignition ConfigMap to disappear once upgrading
IGNITION_CLEANUP_POLL_INTERVAL=10
IGNITION_CLEANUP_POLL_RETRIES=3

# Read a jsonpath field from the DPFHCPProvisioner CR.
get_provisioner_field() {
	local jsonpath="$1"
	oc get dpfhcpprovisioner -n "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" \
		-o jsonpath="${jsonpath}" 2>/dev/null || true
}

# Extract the OCP version from a release image tag (e.g. …:4.22.2-multi -> 4.22.2).
extract_version() {
	echo "$1" | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+'
}

# Verify a release image exists and is pullable.
ensure_release_image_exists() {
	local image="$1"
	echo "Verifying target image: ${image}"
	if ! oc adm release info "${image}" -o jsonpath='{.digest}' &>/dev/null; then
		echo "ERROR: Target image ${image} not found or inaccessible." >&2
		return 1
	fi
}

# If machineOSURL is set, the user must either clear it or provide an updated
# value via HOSTED_UPGRADE_MACHINE_OS_URL. Without this, DPUs would boot with
# a stale OS image after the upgrade.
handle_machine_os_url() {
	local current_url
	current_url=$(get_provisioner_field '{.spec.machineOSURL}')
	if [[ -z "${current_url}" ]]; then
		return 0
	fi

	if [[ -z "${HOSTED_UPGRADE_MACHINE_OS_URL:-}" ]]; then
		local current_repo auto_repo
		current_repo="${current_url%:*}"
		auto_repo=$(oc get dpfhcpprovisionerconfig default \
			-o jsonpath='{.spec.blueFieldOCPLayerRepo}' 2>/dev/null || true)
		echo "ERROR: machineOSURL is set on the DPFHCPProvisioner (${current_url})." >&2
		echo "Set HOSTED_UPGRADE_MACHINE_OS_URL to the new value, or set it to 'remove' to clear it (it's automatically resolved by the operator when not set)." >&2
		echo "To list available tags:" >&2
		echo "  Current machineOSURL repo:" >&2
		echo "    skopeo list-tags --authfile ${OPENSHIFT_PULL_SECRET} docker://${current_repo}" >&2
		if [[ -n "${auto_repo}" && "${auto_repo}" != "${current_repo}" ]]; then
			echo "  Operator auto-resolve repo (DPFHCPProvisionerConfig):" >&2
			echo "    skopeo list-tags --authfile ${OPENSHIFT_PULL_SECRET} docker://${auto_repo}" >&2
		fi
		return 1
	fi

	if [[ "${HOSTED_UPGRADE_MACHINE_OS_URL}" == "remove" ]]; then
		echo "Removing machineOSURL from DPFHCPProvisioner..."
		oc patch dpfhcpprovisioner -n "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" \
			--type json -p '[{"op": "remove", "path": "/spec/machineOSURL"}]'
	else
		echo "Updating machineOSURL to ${HOSTED_UPGRADE_MACHINE_OS_URL}..."
		oc patch dpfhcpprovisioner -n "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" \
			--type merge -p "{\"spec\":{\"machineOSURL\":\"${HOSTED_UPGRADE_MACHINE_OS_URL}\"}}"
	fi
}

# Patch ocpReleaseImage on the DPFHCPProvisioner to initiate the upgrade.
start_upgrade() {
	local new_image="$1"
	echo "Patching DPFHCPProvisioner ${UPGRADE_HOSTED_CLUSTER_NAME} in ${CLUSTERS_NAMESPACE}..."
	oc patch dpfhcpprovisioner -n "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" \
		--type merge -p "{\"spec\":{\"ocpReleaseImage\":\"${new_image}\"}}"
}

# Verify the operator deleted the stale ignition ConfigMap once the upgrade starts.
# The operator deletes bfcfg-<dpuClusterName>.cfg in the DPUCluster namespace
# as part of entering the Upgrading phase — if it's still around, something is wrong.
ensure_ignition_cleaned_up() {
	# Wait for the upgrade phase to actually start
	echo "Waiting for DPFHCPProvisioner to enter Upgrading phase..."
	for ((i = 1; i <= UPGRADE_START_POLL_RETRIES; i++)); do
		local phase
		phase=$(get_provisioner_field '{.status.phase}')
		if [[ "${phase}" == "Upgrading" ]]; then
			break
		fi
		if [[ "${phase}" == "Failed" ]]; then
			echo "ERROR: DPFHCPProvisioner entered Failed phase before upgrading." >&2
			return 1
		fi
		sleep "${UPGRADE_START_POLL_INTERVAL}"
	done

	for ((j = 1; j <= IGNITION_CLEANUP_POLL_RETRIES; j++)); do
		if ! oc get configmap -n "${DPU_CLUSTER_NAMESPACE}" "${IGNITION_CM}" &>/dev/null; then
			echo "Ignition ConfigMap ${IGNITION_CM} cleaned up."
			return 0
		fi
		sleep "${IGNITION_CLEANUP_POLL_INTERVAL}"
	done
	echo "ERROR: Ignition ConfigMap ${IGNITION_CM} still exists during upgrade." >&2
	return 1
}

# Poll the DPFHCPProvisioner until the upgrade finishes
# (phase=Ready, Ready=True, HostedClusterUpgrading!=True).
follow_upgrade_to_completion() {
	local timeout_minutes=$((UPGRADE_POLL_RETRIES * UPGRADE_POLL_INTERVAL / 60))
	echo "Waiting for upgrade to ${HOSTED_UPGRADE_TARGET_VERSION} (timeout: ${timeout_minutes}m)..."

	for ((attempt = 1; attempt <= UPGRADE_POLL_RETRIES; attempt++)); do
		local phase ready upgrading
		phase=$(get_provisioner_field '{.status.phase}')
		ready=$(get_provisioner_field '{.status.conditions[?(@.type=="Ready")].status}')
		upgrading=$(get_provisioner_field '{.status.conditions[?(@.type=="HostedClusterUpgrading")].status}')

		echo "[${attempt}/${UPGRADE_POLL_RETRIES}] phase=${phase} ready=${ready} upgrading=${upgrading}"

		if [[ "${phase}" == "Failed" ]]; then
			echo "ERROR: DPFHCPProvisioner entered Failed phase."
			oc get dpfhcpprovisioner -n "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" -o yaml
			return 1
		fi

		if [[ "${phase}" == "Ready" && "${ready}" == "True" && "${upgrading}" != "True" ]]; then
			echo "Hosted cluster upgrade complete."
			oc get dpfhcpprovisioner -n "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}"
			return 0
		fi
		sleep "${UPGRADE_POLL_INTERVAL}"
	done

	echo "ERROR: Hosted cluster upgrade timed out."
	oc get dpfhcpprovisioner -n "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" -o yaml
	return 1
}

# Verify the operator recreated the ignition ConfigMap with the new release image annotation.
# Checks both the old and new annotation prefix for compatibility across provisioner versions.
ensure_ignition_recreated() {
	local actual_image
	actual_image=$(oc get configmap -n "${DPU_CLUSTER_NAMESPACE}" "${IGNITION_CM}" \
		-o jsonpath="{.metadata.annotations['${IGNITION_RELEASE_ANNOTATION_NEW}']}" 2>/dev/null || true)
	if [[ -z "${actual_image}" ]]; then
		actual_image=$(oc get configmap -n "${DPU_CLUSTER_NAMESPACE}" "${IGNITION_CM}" \
			-o jsonpath="{.metadata.annotations['${IGNITION_RELEASE_ANNOTATION_OLD}']}" 2>/dev/null || true)
	fi

	if [[ -z "${actual_image}" ]]; then
		echo "ERROR: Ignition ConfigMap ${IGNITION_CM} was not recreated after upgrade." >&2
		return 1
	fi

	if [[ "${actual_image}" != "${TARGET_IMAGE}" ]]; then
		echo "ERROR: Ignition ConfigMap has wrong release image annotation." >&2
		echo "  expected: ${TARGET_IMAGE}" >&2
		echo "  actual:   ${actual_image}" >&2
		return 1
	fi

	echo "Ignition ConfigMap ${IGNITION_CM} recreated with correct release image."
}

CURRENT_IMAGE=$(get_provisioner_field '{.spec.ocpReleaseImage}')
echo "Upgrading DPFHCPProvisioner: ${UPGRADE_HOSTED_CLUSTER_NAME} (namespace: ${CLUSTERS_NAMESPACE})"
echo "Current ocpReleaseImage: ${CURRENT_IMAGE}"

CURRENT_VERSION=$(extract_version "${CURRENT_IMAGE}")
echo "Current hosted cluster version: ${CURRENT_VERSION}"

if [[ -z "${HOSTED_UPGRADE_TARGET_VERSION:-}" ]]; then
	current_z="${CURRENT_VERSION##*.}"
	HOSTED_UPGRADE_TARGET_VERSION="${CURRENT_VERSION%.*}.$((current_z + 1))"
	unset current_z
	echo "HOSTED_UPGRADE_TARGET_VERSION not set, defaulting to z+1: ${HOSTED_UPGRADE_TARGET_VERSION}"
	echo "Ensure ${CURRENT_VERSION} is not the latest z-stream, or this will fail."
else
	echo "HOSTED_UPGRADE_TARGET_VERSION explicitly set to ${HOSTED_UPGRADE_TARGET_VERSION}"
fi

TARGET_IMAGE="quay.io/openshift-release-dev/ocp-release:${HOSTED_UPGRADE_TARGET_VERSION}-${HOSTED_ARCH}"

# Ignition ConfigMap name/namespace — derived from the DPUCluster ref, used by
# ensure_ignition_cleaned_up and ensure_ignition_recreated.
DPU_CLUSTER_NAME=$(get_provisioner_field '{.spec.dpuClusterRef.name}')
DPU_CLUSTER_NAMESPACE=$(get_provisioner_field '{.spec.dpuClusterRef.namespace}')
IGNITION_CM="bfcfg-${DPU_CLUSTER_NAME}.cfg"
IGNITION_RELEASE_ANNOTATION_OLD="provisioning.dpu.nvidia.com/bfcfg-template-ocp-release-image"
IGNITION_RELEASE_ANNOTATION_NEW="dpfhcpprovisioner.dpu.hcp.io/bfcfg-template-ocp-release-image"

ensure_release_image_exists "${TARGET_IMAGE}"
handle_machine_os_url
start_upgrade "${TARGET_IMAGE}"
ensure_ignition_cleaned_up
follow_upgrade_to_completion
ensure_ignition_recreated
