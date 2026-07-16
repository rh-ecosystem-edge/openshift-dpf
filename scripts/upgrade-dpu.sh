#!/bin/bash
# Upgrade DPUs by creating a new BFB resource and patching the DPUDeployment.
#
# Creates a new BFB CR (named after the target version) and patches the
# DPUDeployment to reference it. DPF then rolls out the new firmware across
# DPUs.
#
# The DPUDeployment name/namespace are read from the DPFHCPProvisioner's
# dpuDeploymentRef, so the only input needed is which hosted cluster to use.
#
# Variables:
#   DPU_UPGRADE_BFB_URL          - URL for the new BFB image (default: URL from the
#                                   current BFB CR on the DPUDeployment).
#   UPGRADE_HOSTED_CLUSTER_NAME  - DPFHCPProvisioner name (default: HOSTED_CLUSTER_NAME)
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/env.sh"

BFB_TIMEOUT=600

UPGRADE_TIMEOUT=5400

UPGRADE_HOSTED_CLUSTER_NAME="${UPGRADE_HOSTED_CLUSTER_NAME:-${HOSTED_CLUSTER_NAME}}"

get_field() {
	local resource="$1" namespace="$2" name="$3" jsonpath="$4"
	oc get "${resource}" -n "${namespace}" "${name}" \
		-o jsonpath="${jsonpath}"
}

get_dpu_deployment_of_hosted_cluster() {
	DPU_DEPLOYMENT_NAME=$(get_field dpfhcpprovisioner "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" '{.spec.dpuDeploymentRef.name}')
	DPU_DEPLOYMENT_NAMESPACE=$(get_field dpfhcpprovisioner "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" '{.spec.dpuDeploymentRef.namespace}')
	if [[ -z "${DPU_DEPLOYMENT_NAME}" || -z "${DPU_DEPLOYMENT_NAMESPACE}" ]]; then
		echo "ERROR: Could not read dpuDeploymentRef from DPFHCPProvisioner ${UPGRADE_HOSTED_CLUSTER_NAME}." >&2
		return 1
	fi
	echo "DPUDeployment: ${DPU_DEPLOYMENT_NAME} (namespace: ${DPU_DEPLOYMENT_NAMESPACE})"
}

get_current_bfb_of_dpu_deployment() {
	CURRENT_BFB=$(get_field dpudeployment "${DPU_DEPLOYMENT_NAMESPACE}" "${DPU_DEPLOYMENT_NAME}" '{.spec.dpus.bfb}')
	echo "Current BFB: ${CURRENT_BFB}"
}

get_current_bfb_url() {
	CURRENT_BFB_URL=$(get_field bfb "${DPU_DEPLOYMENT_NAMESPACE}" "${CURRENT_BFB}" '{.spec.url}')
	echo "Current BFB URL: ${CURRENT_BFB_URL}"
}

get_current_bfb_components_versions() {
	BFB_VERSION_ATF=$(get_field bfb "${DPU_DEPLOYMENT_NAMESPACE}" "${CURRENT_BFB}" '{.spec.versions.atf}')
	BFB_VERSION_BSP=$(get_field bfb "${DPU_DEPLOYMENT_NAMESPACE}" "${CURRENT_BFB}" '{.spec.versions.bsp}')
	BFB_VERSION_DOCA=$(get_field bfb "${DPU_DEPLOYMENT_NAMESPACE}" "${CURRENT_BFB}" '{.spec.versions.doca}')
	BFB_VERSION_UEFI=$(get_field bfb "${DPU_DEPLOYMENT_NAMESPACE}" "${CURRENT_BFB}" '{.spec.versions.uefi}')
	echo "BFB versions: atf=${BFB_VERSION_ATF} bsp=${BFB_VERSION_BSP} doca=${BFB_VERSION_DOCA} uefi=${BFB_VERSION_UEFI}"
}

ensure_hosted_cluster_upgrade_complete() {
	local phase upgrading
	phase=$(get_field dpfhcpprovisioner "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" '{.status.phase}')
	upgrading=$(get_field dpfhcpprovisioner "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" '{.status.conditions[?(@.type=="HostedClusterUpgrading")].status}')
	if [[ "${phase}" != "Ready" || "${upgrading}" == "True" ]]; then
		echo "ERROR: Hosted cluster upgrade is still in progress (phase=${phase}, upgrading=${upgrading})." >&2
		echo "Complete the hosted cluster upgrade before upgrading DPUs." >&2
		return 1
	fi
}

get_current_hosted_cluster_version() {
	local image
	image=$(get_field dpfhcpprovisioner "${CLUSTERS_NAMESPACE}" "${UPGRADE_HOSTED_CLUSTER_NAME}" '{.spec.ocpReleaseImage}')
	HOSTED_CLUSTER_VERSION=$(echo "${image}" | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+' || true)
	if [[ -z "${HOSTED_CLUSTER_VERSION}" ]]; then
		echo "ERROR: Could not detect version from DPFHCPProvisioner ${UPGRADE_HOSTED_CLUSTER_NAME}." >&2
		return 1
	fi
	echo "Hosted cluster version: ${HOSTED_CLUSTER_VERSION}"
}

get_current_bfb_version() {
	CURRENT_BFB_VERSION=$(echo "${CURRENT_BFB}" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+$' || true)
	if [[ -n "${CURRENT_BFB_VERSION}" ]]; then
		echo "Current BFB version: ${CURRENT_BFB_VERSION}"
	else
		echo "Current BFB has no version in its name."
	fi
}

ensure_url_change_on_minor_upgrade() {
	if [[ -z "${CURRENT_BFB_VERSION}" ]]; then
		echo "Current BFB has no version in its name, skipping minor version check."
		return 0
	fi
	local current_bfb_minor="${CURRENT_BFB_VERSION%.*}"
	local hosted_cluster_minor="${HOSTED_CLUSTER_VERSION%.*}"
	if [[ "${current_bfb_minor}" != "${hosted_cluster_minor}" && -z "${DPU_UPGRADE_BFB_URL:-}" ]]; then
		echo "ERROR: Minor version upgrade detected (${current_bfb_minor} -> ${hosted_cluster_minor})." >&2
		echo "Set DPU_UPGRADE_BFB_URL to the BFB image for the new minor version." >&2
		return 1
	fi
}

assemble_new_bfb_cr_name() {
	local bfb_prefix="${CURRENT_BFB%-[0-9]*.[0-9]*.[0-9]*}"
	NEW_BFB_NAME="${bfb_prefix}-${HOSTED_CLUSTER_VERSION}"
	echo "Target BFB: ${NEW_BFB_NAME}"
}

# Create a new BFB CR for the target version.
create_new_bfb() {
	local new_bfb_name="$1" new_bfb_url="$2"

	# The name must be different from other BFBs. Hopefully NVIDIA fixes this
	# in the future to avoid redownloading.
	local bfb_internal_filename="${new_bfb_name}.bfb"

	if oc get bfb -n "${DPU_DEPLOYMENT_NAMESPACE}" "${new_bfb_name}" &>/dev/null; then
		local existing_url
		existing_url=$(oc get bfb -n "${DPU_DEPLOYMENT_NAMESPACE}" "${new_bfb_name}" -o jsonpath='{.spec.url}')
		if [[ "${existing_url}" != "${new_bfb_url}" ]]; then
			echo "ERROR: BFB ${new_bfb_name} already exists with a different URL." >&2
			echo "  Existing: ${existing_url}" >&2
			echo "  Requested: ${new_bfb_url}" >&2
			echo "Delete it first: oc --kubeconfig=${KUBECONFIG} delete bfb -n ${DPU_DEPLOYMENT_NAMESPACE} ${new_bfb_name}" >&2
			return 1
		fi
		echo "BFB ${new_bfb_name} already exists with matching URL, skipping creation."
		return
	fi

	echo "Creating BFB ${new_bfb_name}..."
	cat <<-EOF | oc apply -f -
		apiVersion: provisioning.dpu.nvidia.com/v1alpha1
		kind: BFB
		metadata:
		  name: ${new_bfb_name}
		  namespace: ${DPU_DEPLOYMENT_NAMESPACE}
		spec:
		  fileName: ${bfb_internal_filename}
		  url: ${new_bfb_url}
		  versions:
		    atf: "${BFB_VERSION_ATF}"
		    bsp: "${BFB_VERSION_BSP}"
		    doca: "${BFB_VERSION_DOCA}"
		    uefi: "${BFB_VERSION_UEFI}"
	EOF
}

wait_for_bfb_ready() {
	local bfb_name="$1"
	echo "Waiting for BFB ${bfb_name} to be Ready (timeout: $((BFB_TIMEOUT / 60))m)..."
	if ! oc wait bfb -n "${DPU_DEPLOYMENT_NAMESPACE}" "${bfb_name}" \
		--for=condition=Ready --timeout="${BFB_TIMEOUT}s"; then
		echo "ERROR: BFB ${bfb_name} did not become Ready in time."
		oc get bfb -n "${DPU_DEPLOYMENT_NAMESPACE}" "${bfb_name}" -o yaml
		return 1
	fi
	echo "BFB ${bfb_name} is Ready."
}

# Patch the DPUDeployment to reference the new BFB.
patch_dpudeployment() {
	local new_bfb_name="$1"
	echo "Patching DPUDeployment ${DPU_DEPLOYMENT_NAME} to use BFB ${new_bfb_name}..."
	oc patch dpudeployment -n "${DPU_DEPLOYMENT_NAMESPACE}" "${DPU_DEPLOYMENT_NAME}" \
		--type merge -p "{\"spec\":{\"dpus\":{\"bfb\":\"${new_bfb_name}\"}}}"
}

# Wait for the DPUDeployment to become Ready after the upgrade.
# Polls instead of using "oc wait" because the DPU operator can briefly set
# Ready=True during reconciliation before starting the actual rollout.
follow_upgrade_to_completion() {
	local gen
	gen=$(oc get dpudeployment -n "${DPU_DEPLOYMENT_NAMESPACE}" "${DPU_DEPLOYMENT_NAME}" \
		-o jsonpath='{.metadata.generation}')
	echo "Waiting for DPUDeployment upgrade to complete (generation: ${gen}, timeout: $((UPGRADE_TIMEOUT / 60))m)..."

	local deadline=$((SECONDS + UPGRADE_TIMEOUT))
	local saw_not_ready=false
	while ((SECONDS < deadline)); do
		local ready
		ready=$(oc get dpudeployment -n "${DPU_DEPLOYMENT_NAMESPACE}" "${DPU_DEPLOYMENT_NAME}" \
			-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

		if [[ "${ready}" != "True" ]]; then
			saw_not_ready=true
		fi

		if [[ "${saw_not_ready}" == "true" && "${ready}" == "True" ]]; then
			echo "DPU upgrade complete."
			oc get dpudeployment -n "${DPU_DEPLOYMENT_NAMESPACE}" "${DPU_DEPLOYMENT_NAME}"
			return 0
		fi

		echo "  ready=${ready}"
		sleep 30
	done

	echo "ERROR: DPU upgrade timed out."
	oc get dpudeployment -n "${DPU_DEPLOYMENT_NAMESPACE}" "${DPU_DEPLOYMENT_NAME}" -o yaml
	return 1
}

get_upgrade_bfb_url() {
	DPU_UPGRADE_BFB_URL="${DPU_UPGRADE_BFB_URL:-${CURRENT_BFB_URL}}"
	if [[ -z "${DPU_UPGRADE_BFB_URL}" ]]; then
		echo "ERROR: Could not determine BFB URL. Set DPU_UPGRADE_BFB_URL explicitly." >&2
		return 1
	fi
	echo "BFB URL: ${DPU_UPGRADE_BFB_URL}"
}

check_already_upgraded() {
	local current_bfb="$1" target_bfb="$2"
	if [[ "${current_bfb}" != "${target_bfb}" ]]; then
		return 1
	fi
	local ready
	ready=$(get_field dpudeployment "${DPU_DEPLOYMENT_NAMESPACE}" "${DPU_DEPLOYMENT_NAME}" '{.status.conditions[?(@.type=="Ready")].status}')
	if [[ "${ready}" == "True" ]]; then
		echo "DPUDeployment already references ${target_bfb} and is Ready, nothing to do."
		return 0
	fi
	echo "DPUDeployment already references ${target_bfb} but Ready=${ready}, resuming monitoring..."
	follow_upgrade_to_completion || {
		echo "ERROR: Upgrade monitoring failed." >&2
		exit 1
	}
}

ensure_hosted_cluster_upgrade_complete
get_dpu_deployment_of_hosted_cluster
get_current_bfb_of_dpu_deployment
get_current_bfb_url
get_current_bfb_components_versions
get_current_bfb_version
get_current_hosted_cluster_version
ensure_url_change_on_minor_upgrade
assemble_new_bfb_cr_name
get_upgrade_bfb_url
check_already_upgraded "${CURRENT_BFB}" "${NEW_BFB_NAME}" && exit 0
create_new_bfb "${NEW_BFB_NAME}" "${DPU_UPGRADE_BFB_URL}"
wait_for_bfb_ready "${NEW_BFB_NAME}"
patch_dpudeployment "${NEW_BFB_NAME}"
follow_upgrade_to_completion
