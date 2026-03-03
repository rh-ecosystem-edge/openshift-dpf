#!/bin/bash
# enable-ovn-injector.sh - Enable OVN resource injector via MutatingWebhookConfiguration

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

log [INFO] "Enabling OVN resource injector..."

rm -rf "$GENERATED_DIR/ovn-injector" || true
mkdir -p "$GENERATED_DIR/ovn-injector"

INJECTOR_RESOURCE_NAME="${INJECTOR_RESOURCE_NAME:-openshift.io/bf3-p0-vfs}"

# Escape the resource name for JSON Patch path (/ becomes ~1)
INJECTOR_RESOURCE_NAME_ESCAPED=$(echo "${INJECTOR_RESOURCE_NAME}" | sed 's/\//~1/g')

helm pull "${OVN_CHART_URL}/ovn-kubernetes-chart" \
    --version "${INJECTOR_CHART_VERSION}" \
    --untar -d "$GENERATED_DIR/ovn-injector"

helm template -n ${OVNK_NAMESPACE} ovn-kubernetes \
    "$GENERATED_DIR/ovn-injector/ovn-kubernetes-chart" \
    --set ovn-kubernetes-resource-injector.enabled=true \
    --set ovn-kubernetes-resource-injector.resourceName="${INJECTOR_RESOURCE_NAME}" \
    --set nodeWithDPUManifests.enabled=false \
    --set nodeWithoutDPUManifests.enabled=false \
    --set dpuManifests.enabled=false \
    --set controlPlaneManifests.enabled=false \
    --set commonManifests.enabled=false \
    | oc apply -f -

rm -rf "$GENERATED_DIR/ovn-injector"

# Wait for the webhook deployment to roll out
log [INFO] "Waiting for OVN resource injector deployment to roll out..."
if ! oc rollout status deployment/ovn-kubernetes-ovn-kubernetes-resource-injector -n "${OVNK_NAMESPACE}" --timeout=120s; then
    log [ERROR] "OVN resource injector deployment failed to roll out"
    exit 1
fi
log [INFO] "OVN resource injector deployment rolled out successfully"

# Verify MutatingWebhookConfiguration creation
log [INFO] "Verifying OVN injector MutatingWebhookConfiguration creation..."
if oc get mutatingwebhookconfiguration ovn-kubernetes-ovn-kubernetes-resource-injector &>/dev/null; then
    log [INFO] "MutatingWebhookConfiguration 'ovn-kubernetes-ovn-kubernetes-resource-injector' created successfully"
else
    log [ERROR] "MutatingWebhookConfiguration 'ovn-kubernetes-ovn-kubernetes-resource-injector' was not created"
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
