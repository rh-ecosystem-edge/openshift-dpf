#!/bin/bash
# enable-ovn-injector.sh - Enable OVN resource injector via MutatingAdmissionPolicy

# Exit on error
set -e

# Source common utilities and configuration
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

# Set cluster-specific values
API_SERVER="api.$CLUSTER_NAME.$BASE_DOMAIN:6443"

# Get kubeconfig
get_kubeconfig

# Ensure helm is installed
ensure_helm_installed

log [INFO] "Enabling OVN resource injector via MutatingAdmissionPolicy..."

rm -rf "$GENERATED_DIR/ovn-injector" || true
mkdir -p "$GENERATED_DIR/ovn-injector"

INJECTOR_RESOURCE_NAME="${INJECTOR_RESOURCE_NAME:-openshift.io/bf3-p0-vfs}"

# Escape the resource name for JSON Patch path (/ becomes ~1)
INJECTOR_RESOURCE_NAME_ESCAPED=$(echo "${INJECTOR_RESOURCE_NAME}" | sed 's/\//~1/g')

# Patch control plane nodes with fake resource capacity/allocatable
# This is required for the MutatingAdmissionPolicy to work correctly.
# All control plane nodes are patched with a high number of resources with the same name as the VF resource
# exposed by the device plugin. These devices are only exposed on the Node and have no device plugin managing allocations.
# Pods scheduled to the control plane nodes will consume these resources, but Multus will not use them when it calls the
# OVN Kubernetes CNI for pod creation. This is because these devices will not be advertised by kubelet's podresources API.
#
# NOTE: This patch only applies to existing control plane nodes at the time this script runs.
#       Any new control plane nodes added to the cluster will need to be patched manually.
log [INFO] "Patching control plane nodes with resource capacity..."
for node in $(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do
    log [INFO] "Patching node: $node"
    oc patch node "$node" --subresource=status --type=json -p="[
        {\"op\": \"add\", \"path\": \"/status/capacity/${INJECTOR_RESOURCE_NAME_ESCAPED}\", \"value\": \"10000\"},
        {\"op\": \"add\", \"path\": \"/status/allocatable/${INJECTOR_RESOURCE_NAME_ESCAPED}\", \"value\": \"10000\"}
    ]"
done
log [INFO] "Control plane nodes patched successfully"

helm pull "${OVN_CHART_URL}/ovn-kubernetes-chart" \
    --version "${INJECTOR_CHART_VERSION}" \
    --untar -d "$GENERATED_DIR/ovn-injector"

helm template -n ${OVNK_NAMESPACE} ovn-kubernetes \
    "$GENERATED_DIR/ovn-injector/ovn-kubernetes-chart" \
    --set ovn-kubernetes-resource-injector.enabled=true \
    --set resourceName="${INJECTOR_RESOURCE_NAME}" \
    --set nodeWithDPUManifests.enabled=false \
    --set nodeWithoutDPUManifests.enabled=false \
    --set dpuManifests.enabled=false \
    --set controlPlaneManifests.enabled=false \
    --set commonManifests.enabled=false \
    | oc apply -f -

rm -rf "$GENERATED_DIR/ovn-injector"

# Verify MutatingAdmissionPolicy creation
log [INFO] "Verifying OVN injector MutatingAdmissionPolicy creation..."
if oc get mutatingadmissionpolicies.admissionregistration.k8s.io ovn-kubernetes-resource-injector &>/dev/null; then
    log [INFO] "MutatingAdmissionPolicy 'ovn-kubernetes-resource-injector' created successfully"
else
    log [ERROR] "MutatingAdmissionPolicy 'ovn-kubernetes-resource-injector' was not created"
    exit 1
fi

# Verify NAD creation
if oc get net-attach-def -n "${OVNK_NAMESPACE}" dpf-ovn-kubernetes &>/dev/null; then
    log [INFO] "NetworkAttachmentDefinition 'dpf-ovn-kubernetes' created successfully"
else
    log [ERROR] "NetworkAttachmentDefinition 'dpf-ovn-kubernetes' was not created"
    exit 1
fi

log [INFO] "OVN resource injector enabled successfully"
