#!/bin/bash
# dpf.sh - DPF deployment operations

# Exit on error and catch pipe failures
set -e
set -o pipefail

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

ETCD_STORAGE_CLASS=${ETCD_STORAGE_CLASS:-"ocs-storagecluster-ceph-rbd"}

# -----------------------------------------------------------------------------
# DPF deployment functions
# -----------------------------------------------------------------------------
function deploy_nfd() {
    log [INFO] "Managing NFD deployment..."

    get_kubeconfig

    # Check if NFD subscription exists, if not apply it
    if ! oc get subscription -n openshift-nfd nfd &>/dev/null; then
        log [INFO] "NFD subscription not found. Applying NFD subscription..."
        apply_manifest "$MANIFESTS_DIR/cluster-installation/nfd-subscription.yaml"
        
        # Verify operator is ready by checking CSV
        log [INFO] "Verifying NFD operator installation..."
        if ! retry 30 10 bash -c 'oc get csv -n openshift-nfd -o jsonpath="{.items[*].status.phase}" | grep -q "Succeeded"'; then
            log [ERROR] "Timeout: NFD operator installation failed"
            return 1
        fi
        log [INFO] "NFD operator installation verified successfully"
    else
        log [INFO] "NFD subscription already exists. Skipping deployment."
    fi

    log [INFO] "Creating NFD instance..."
    mkdir -p "$GENERATED_DIR"
    cp "$MANIFESTS_DIR/dpf-installation/nfd-cr-template.yaml" "$GENERATED_DIR/nfd-cr-template.yaml"
    echo
    sed -i "s|api.<CLUSTER_FQDN>|$HOST_CLUSTER_API|g" "$GENERATED_DIR/nfd-cr-template.yaml"

    # Apply the NFD CR
    KUBECONFIG=$KUBECONFIG oc apply -f "$GENERATED_DIR/nfd-cr-template.yaml"

    log [INFO] "NFD deployment completed successfully!"
}


function deploy_metallb() {
    # Only deploy MetalLB if HYPERSHIFT_API_IP is configured
    if [ -z "${HYPERSHIFT_API_IP}" ]; then
        log [INFO] "HYPERSHIFT_API_IP not set. Skipping MetalLB deployment."
        return 0
    fi
    
    
    log [INFO] "Deploying MetalLB operator for Hypershift API LoadBalancer..."
    
    get_kubeconfig
    
    # Check if MetalLB subscription already exists
    if oc get subscription -n openshift-operators metallb-operator &>/dev/null; then
        log [INFO] "MetalLB subscription already exists. Skipping subscription deployment."
    else
        log [INFO] "Deploying MetalLB subscription..."
        mkdir -p "$GENERATED_DIR"
        
        # Process subscription template
        process_template \
            "${MANIFESTS_DIR}/metallb/metallb-subscription.yaml" \
            "${GENERATED_DIR}/metallb-subscription.yaml" \
            "<CATALOG_SOURCE_NAME>" "${CATALOG_SOURCE_NAME}"
        
        apply_manifest "${GENERATED_DIR}/metallb-subscription.yaml" true  
    fi
    
    log [INFO] "Waiting for MetalLB operator to be ready..."
    wait_for_pods "openshift-operators" "control-plane=controller-manager" 60 5
    
    log [INFO] "Creating MetalLB instance..."

    # Process MetalLB CR template (only the MetalLB instance, not IPAddressPool/L2Advertisement)
    # Note: IPAddressPool and L2Advertisement are now managed by dpf-hcp-provisioner-operator
    process_template \
        "${MANIFESTS_DIR}/metallb/metallb-objects.yaml" \
        "${GENERATED_DIR}/metallb-objects.yaml"
    
    # Apply MetalLB CR
    retry 5 10 apply_manifest "${GENERATED_DIR}/metallb-objects.yaml" true
            
    log [INFO] "MetalLB operator deployment completed successfully!"
    log [INFO] "Note: IPAddressPool and L2Advertisement will be managed by dpf-hcp-provisioner-operator"
}

function apply_scc() {
    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        log [INFO] "Granting the privileged SCC to the Zero Trust DPF default service account..."
        oc adm policy add-scc-to-user privileged \
            -z default \
            -n dpf-operator-system
        return
    fi

    local scc_file="$GENERATED_DIR/scc.yaml"
    if [ -f "$scc_file" ]; then
        log [INFO] "Applying SCC..."
        apply_manifest "$scc_file"
        sleep 5
    fi
}

function apply_namespaces() {
    log [INFO] "Applying namespaces..."
    for file in "$GENERATED_DIR"/*-ns.yaml; do
        if [ -f "$file" ]; then
            local namespace=$(grep -m 1 "name:" "$file" | awk '{print $2}')
            if [ -z "$namespace" ]; then
                log [ERROR] "Failed to extract namespace from $file"
                return 1
            fi
            if check_namespace_exists "$namespace"; then
                log [INFO] "Skipping namespace $namespace creation"
            else
                apply_manifest "$file"
            fi
        fi
    done
}

function deploy_cert_manager() {
    local cert_manager_file="$GENERATED_DIR/openshift-cert-manager.yaml"
    if [ -f "$cert_manager_file" ]; then
        # Check if cert-manager is already installed
        if oc get deployment -n cert-manager cert-manager &>/dev/null; then
            log [INFO] "Cert-manager already installed. Skipping deployment."
            return 0
        fi
        
        log [INFO] "Deploying cert-manager..."
        apply_manifest "$cert_manager_file"
        
        # Wait for cert-manager namespace to be created by the operator
        log [INFO] "Waiting for cert-manager namespace to be created..."
        local retries=30
        while [ $retries -gt 0 ]; do
            if oc get namespace cert-manager &>/dev/null; then
                log [INFO] "cert-manager namespace found"
                break
            fi
            sleep 5
            retries=$((retries-1))
        done
        
        # Verify namespace was actually created
        if [ $retries -eq 0 ]; then
            log [ERROR] "Timeout: cert-manager namespace was not created after 150 seconds"
            return 1
        fi
        
        # Wait for webhook pod in cert-manager namespace
        wait_for_pods "cert-manager" "app.kubernetes.io/component=webhook" 30 5
        log [INFO] "Waiting for cert-manager to stabilize..."
        sleep 5
    fi
}

function deploy_dpf_hcp_provisioner_operator() {
    log [INFO] "Deploying DPF HCP Provisioner Operator..."

    # Ensure helm is installed
    ensure_helm_installed

    log [INFO] "Installing/upgrading DPF HCP Provisioner Operator..."

    local version_flag=""
    if [[ -n "${DPF_HCP_PROVISIONER_OPERATOR_VERSION}" ]]; then
        version_flag="--version ${DPF_HCP_PROVISIONER_OPERATOR_VERSION}"
    fi

    local manage_dpu_service_templates=true
    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        manage_dpu_service_templates=false
        log [INFO] "Zero Trust mode: using the local HBN DPUServiceTemplate"
    fi

    if helm upgrade --install dpf-hcp-provisioner-operator \
        "${DPF_HCP_PROVISIONER_OPERATOR_CHART_URL}" \
        --namespace ${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE} \
        --create-namespace \
        --disable-openapi-validation \
        --registry-config "${OPENSHIFT_PULL_SECRET}" \
        ${version_flag} \
        --set image.repository=${DPF_HCP_PROVISIONER_OPERATOR_IMAGE_REPO} \
        --set image.pullPolicy=Always \
        --set image.tag=${DPF_HCP_PROVISIONER_OPERATOR_IMAGE_TAG} \
        --set provisionerConfig.manageDPUServiceTemplates=${manage_dpu_service_templates}; then

        log [INFO] "Helm release 'dpf-hcp-provisioner-operator' deployed successfully"
        log [INFO] "DPF HCP Provisioner Operator deployment initiated. Use 'oc get pods -n ${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE}' to monitor progress."
    else
        log [ERROR] "Helm deployment of DPF HCP Provisioner Operator failed"
        return 1
    fi

    log [INFO] "Waiting for DPF HCP Provisioner Operator to be ready..."
    wait_for_pods "${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE}" "app.kubernetes.io/name=dpf-hcp-provisioner-operator" 60 10

    log [INFO] "DPF HCP Provisioner Operator is ready!"
}

function deploy_dpu_worker_config() {
    log [INFO] "Deploying DPU Worker Config chart..."

    ensure_helm_installed

    local version_flag=""
    if [[ -n "${DPU_WORKER_CONFIG_CHART_VERSION}" ]]; then
        version_flag="--version ${DPU_WORKER_CONFIG_CHART_VERSION}"
    fi

    if helm upgrade --install dpu-worker-config \
        "${DPU_WORKER_CONFIG_CHART_URL}" \
        --namespace ${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE} \
        --create-namespace \
        --disable-openapi-validation \
        --registry-config "${OPENSHIFT_PULL_SECRET}" \
        ${version_flag}; then
        log [INFO] "Helm release 'dpu-worker-config' deployed successfully"
    else
        log [ERROR] "Helm deployment of dpu-worker-config failed"
        return 1
    fi
}

function create_dpfhcpprovisioner_secrets() {
    log [INFO] "Creating secrets in ${CLUSTERS_NAMESPACE} namespace..."

    # Create namespace if it doesn't exist
    oc create namespace ${CLUSTERS_NAMESPACE} || true

    # Create pull-secret
    log [INFO] "Creating pull secret ${DPFHCPPROVISIONER_PULL_SECRET_NAME}..."
    oc create secret generic ${DPFHCPPROVISIONER_PULL_SECRET_NAME} \
        --from-file=.dockerconfigjson=${OPENSHIFT_PULL_SECRET} \
        -n ${CLUSTERS_NAMESPACE} \
        --type=Opaque || true

    # Create SSH key secret
    log [INFO] "Creating SSH key secret ${DPFHCPPROVISIONER_SSH_SECRET_NAME}..."
    oc create secret generic ${DPFHCPPROVISIONER_SSH_SECRET_NAME} \
        --from-file=id_rsa.pub=${SSH_KEY} \
        -n ${CLUSTERS_NAMESPACE} \
        --type=Opaque || true

    log [INFO] "Secrets created successfully in ${CLUSTERS_NAMESPACE} namespace"
}

function create_dpfhcpprovisioner_cr() {
    log [INFO] "Creating DPFHCPProvisioner Custom Resource..."

    # Ensure generated directory exists
    mkdir -p "${GENERATED_DIR}"

    # Ensure namespace exists
    oc create namespace ${CLUSTERS_NAMESPACE} || true

    # Check if DPFHCPProvisioner CR already exists
    if oc get dpfhcpprovisioner -n ${CLUSTERS_NAMESPACE} ${HOSTED_CLUSTER_NAME} &>/dev/null; then
        log [INFO] "DPFHCPProvisioner CR ${HOSTED_CLUSTER_NAME} already exists. Skipping creation."
        return 0
    fi

    # Determine control plane availability policy based on VM_COUNT
    local control_plane_policy
    if [ "${VM_COUNT}" -gt 1 ]; then
        control_plane_policy="HighlyAvailable"
        log [INFO] "Multi-node cluster (VM_COUNT=${VM_COUNT}). Using HighlyAvailable control plane policy."
    else
        control_plane_policy="SingleReplica"
        log [INFO] "Single-node cluster (VM_COUNT=${VM_COUNT}). Using SingleReplica control plane policy."
    fi

    # Process template to generate DPFHCPProvisioner CR
    local cr_file="${GENERATED_DIR}/dpfhcpprovisioner-${HOSTED_CLUSTER_NAME}.yaml"

    process_template \
        "${MANIFESTS_DIR}/dpf-hcp-provisioner-operator/dpfhcpprovisioner-cr-template.yaml" \
        "${cr_file}" \
        "<HOSTED_CLUSTER_NAME>" "${HOSTED_CLUSTER_NAME}" \
        "<CLUSTERS_NAMESPACE>" "${CLUSTERS_NAMESPACE}" \
        "<BASE_DOMAIN>" "${BASE_DOMAIN}" \
        "<ETCD_STORAGE_CLASS>" "${ETCD_STORAGE_CLASS}" \
        "<OCP_RELEASE_IMAGE>" "${OCP_RELEASE_IMAGE}" \
        "<DPFHCPPROVISIONER_PULL_SECRET_NAME>" "${DPFHCPPROVISIONER_PULL_SECRET_NAME}" \
        "<DPFHCPPROVISIONER_SSH_SECRET_NAME>" "${DPFHCPPROVISIONER_SSH_SECRET_NAME}" \
        "<CONTROL_PLANE_POLICY>" "${control_plane_policy}" \
        "<BLUEFIELD_OCP_IMAGE>" "${BLUEFIELD_OCP_IMAGE}"

    # Add virtualIP if HYPERSHIFT_API_IP is set
    if [ -n "${HYPERSHIFT_API_IP}" ]; then
        cat >> "${cr_file}" << EOF

  # Virtual IP for LoadBalancer
  virtualIP: ${HYPERSHIFT_API_IP}
EOF
        log [INFO] "Added virtualIP: ${HYPERSHIFT_API_IP} to DPFHCPProvisioner CR"
    fi

    # Apply the DPFHCPProvisioner CR using apply_manifest
    log [INFO] "Applying DPFHCPProvisioner CR from ${cr_file}..."
    apply_manifest "${cr_file}" true

    log [INFO] "DPFHCPProvisioner CR ${HOSTED_CLUSTER_NAME} created successfully!"
    log [INFO] "Monitoring DPFHCPProvisioner status..."

    # Show initial status
    oc get dpfhcpprovisioner -n ${CLUSTERS_NAMESPACE} ${HOSTED_CLUSTER_NAME} || true
}

function deploy_hosted_cluster() {
    deploy_hypershift
}

function deploy_dpfhcp() {
    log [INFO] "================================================================================"
    log [INFO] "Deploying DPF HCP Provisioner"
    log [INFO] "================================================================================"

    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        log [INFO] "Zero Trust mode: skipping host DPU worker configuration"
    else
        deploy_dpu_worker_config
    fi
    deploy_dpf_hcp_provisioner_operator
}

function create_hosted_cluster() {
    log [INFO] "================================================================================"
    log [INFO] "Creating Hosted Cluster via DPFHCPProvisioner"
    log [INFO] "================================================================================"

    local hosted_kubeconfig="${HOSTED_CLUSTER_NAME}.kubeconfig"
    if [ "$(readlink -m "${KUBECONFIG}")" = "$(readlink -m "${hosted_kubeconfig}")" ]; then
        log [ERROR] "Management KUBECONFIG value '${KUBECONFIG}' must differ from hosted-cluster kubeconfig '${hosted_kubeconfig}'"
        return 1
    fi

    if [ -n "${HYPERSHIFT_API_IP}" ]; then
        log [INFO] "HYPERSHIFT_API_IP configured. Deploying MetalLB operator for LoadBalancer support..."
        deploy_metallb
    elif [ "${VM_COUNT}" -gt 1 ]; then
        log [WARN] "Multi-node cluster detected but HYPERSHIFT_API_IP not set."
        log [WARN] "Hypershift API will use NodePort instead of LoadBalancer."
    fi

    create_dpfhcpprovisioner_secrets
    create_dpfhcpprovisioner_cr

    log [INFO] "Waiting for DPF HCP Provisioner Operator to create HostedCluster..."
    if ! retry 5 30 oc get hostedcluster -n ${CLUSTERS_NAMESPACE} ${HOSTED_CLUSTER_NAME} &>/dev/null; then
        log [ERROR] "Timeout: HostedCluster was not created after 2.5 minutes"
        log [ERROR] "Check DPFHCPProvisioner CR status:"
        oc get dpfhcpprovisioner -n ${CLUSTERS_NAMESPACE} ${HOSTED_CLUSTER_NAME} -o yaml
        return 1
    fi

    log [INFO] "HostedCluster ${HOSTED_CLUSTER_NAME} created by operator in ${CLUSTERS_NAMESPACE}"

    if [ -n "${CNO_HCP_IMAGE}" ]; then
        add_cno_image_override
    fi

    log [INFO] "Waiting for hosted control plane namespace ${HOSTED_CONTROL_PLANE_NAMESPACE}..."
    retry 30 10 bash -c "oc get namespace ${HOSTED_CONTROL_PLANE_NAMESPACE} &>/dev/null"

    log [INFO] "Checking hosted control plane pods..."
    oc -n ${HOSTED_CONTROL_PLANE_NAMESPACE} get pods || true

    log [INFO] "Waiting for etcd StorageClass ${ETCD_STORAGE_CLASS} before expecting etcd pods to schedule..."
    wait_for_storage_class "${ETCD_STORAGE_CLASS}" || return 1

    log [INFO] "Waiting for etcd pods..."
    wait_for_pods ${HOSTED_CONTROL_PLANE_NAMESPACE} "app=etcd" 60 10

    configure_hypershift

    log [INFO] "================================================================================"
    log [INFO] "Hosted Cluster deployment via DPF HCP Provisioner Operator completed!"
    log [INFO] "================================================================================"
}

function deploy_hypershift() {
    log [INFO] "================================================================================"
    log [INFO] "Deploying Hosted Cluster using DPF HCP Provisioner Operator"
    log [INFO] "================================================================================"

    if oc get deployment -n hypershift operator &>/dev/null; then
        log [INFO] "Hypershift operator already installed. Skipping deployment."
    else
        case "${HYPERSHIFT_INSTALL_METHOD}" in
            mce)
                log [INFO] "Installing Hypershift via MultiCluster Engine (MCE)..."
                install_hypershift_via_mce
                ;;
            binary)
                log [INFO] "Installing latest hypershift operator via binary..."
                install_hypershift
                wait_for_pods "hypershift" "app=operator" 60 10
                ;;
            *)
                log [ERROR] "Unknown HYPERSHIFT_INSTALL_METHOD: ${HYPERSHIFT_INSTALL_METHOD}. Valid values: binary, mce"
                return 1
                ;;
        esac
    fi

    deploy_dpfhcp
    create_hosted_cluster
}

function add_cno_image_override() {
    log [INFO] "Adding CNO image override annotation..."
    local max_retries=10
    local retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        if oc annotate hostedcluster -n ${CLUSTERS_NAMESPACE} ${HOSTED_CLUSTER_NAME} \
           hypershift.openshift.io/image-overrides=cluster-network-operator=${CNO_HCP_IMAGE} \
           --overwrite; then
            log [INFO] "Successfully added CNO image override annotation"
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                log [WARN] "Failed to annotate hosted cluster (attempt $retry_count/$max_retries), retrying in 5s..."
                sleep 5
            else
                log [ERROR] "Failed to annotate hosted cluster after $max_retries attempts"
            fi
        fi
    done
}

function configure_hypershift() {
    log [INFO] "Creating kubeconfig for Hypershift hosted cluster..."

    local secret_retries=180

    # Wait for the HostedCluster resource to create the admin-kubeconfig secret with valid data
    wait_for_secret_with_data "${CLUSTERS_NAMESPACE}" "${HOSTED_CLUSTER_NAME}-admin-kubeconfig" "kubeconfig" "${secret_retries}" 10

    log [INFO] "Generating kubeconfig file for ${HOSTED_CLUSTER_NAME}..."
    local max_attempts=5
    local delay=10
    retry "$max_attempts" "$delay" bash -c '
        ns="$1"; name="$2"
        hypershift create kubeconfig --namespace "$ns" --name "$name" > "$name.kubeconfig" && \
        grep -q "apiVersion: v1" "$name.kubeconfig" && \
        grep -q "kind: Config" "$name.kubeconfig"
    ' _ "${CLUSTERS_NAMESPACE}" "${HOSTED_CLUSTER_NAME}"

    # Wait for the dpf-hcp-provisioner-operator to copy the secret to dpf-operator-system namespace
    log [INFO] "Waiting for dpf-hcp-provisioner-operator to create kubeconfig secret in dpf-operator-system..."
    if ! retry "${secret_retries}" 10 oc get secret -n dpf-operator-system "${HOSTED_CLUSTER_NAME}-admin-kubeconfig" &>/dev/null; then
        log [ERROR] "Timeout: dpf-hcp-provisioner-operator did not create kubeconfig secret in dpf-operator-system"
        return 1
    fi
    log [INFO] "Kubeconfig secret successfully created by dpf-hcp-provisioner-operator in dpf-operator-system"
}

function apply_remaining() {
    log [INFO] "Applying remaining manifests..."
    for file in "$GENERATED_DIR"/*.yaml; do
        # Skip NFD deployment if DISABLE_NFD is set to true
        if [[ "${DISABLE_NFD}" = "true" && "$file" =~ .*dpf-nfd\.yaml$ ]]; then
            log [INFO] "Skipping NFD deployment (DISABLE_NFD explicitly set to true)"
            continue
        fi

        if [[ ! "$file" =~ .*(-ns)\.yaml$ && \
              ! "$file" =~ .*(-crd)\.yaml$ && \
              "$file" != "$GENERATED_DIR/cert-manager-manifests.yaml" && \
              "$file" != "$GENERATED_DIR/scc.yaml" && \
              "$file" != "$GENERATED_DIR/dpudiscovery.yaml" ]]; then
            retry 5 30 apply_manifest "$file" true
            if [[ "$file" =~ .*operator.*\.yaml$ ]]; then
                log [INFO] "Waiting for operator resources..."
                sleep 10
            fi
        fi
    done
}

function wait_for_dpf_provisioning_api() {
    log [INFO] "Waiting for the DPF provisioning API..."
    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        oc wait --for=condition=Established \
            crd/dpudiscoveries.provisioning.dpu.nvidia.com \
            --timeout=10m
    fi

    oc rollout status \
        deployment/dpf-provisioning-controller-manager \
        -n dpf-operator-system \
        --timeout=10m
    oc rollout status \
        deployment/dpuservice-controller-manager \
        -n dpf-operator-system \
        --timeout=10m
    retry 60 5 bash -c \
        'oc get endpoints dpf-provisioning-webhook-service -n dpf-operator-system -o jsonpath="{.subsets[*].addresses[*].ip}" | grep -q .'
}

function zero_trust_dpu_discovery() {
    local discovery_manifest="${GENERATED_DIR}/dpudiscovery.yaml"
    if [ ! -f "${discovery_manifest}" ]; then
        log [ERROR] "Zero Trust DPUDiscovery manifest not found: ${discovery_manifest}"
        return 1
    fi

    log [INFO] "Applying Zero Trust DPUDiscovery through Redfish/OOB"
    apply_manifest "${discovery_manifest}" true

    local serial_variable serial
    while IFS= read -r serial_variable; do
        serial="${!serial_variable:-}"
        [ -n "${serial}" ] || continue

        if ! wait_for_resource dpf-operator-system \
            dpudevices.provisioning.dpu.nvidia.com "${serial}" 60 10; then
            log [ERROR] "DPUDevice ${serial} was not discovered within 10 minutes"
            oc get dpudiscoveries.provisioning.dpu.nvidia.com \
                -n dpf-operator-system || true
            return 1
        fi

        if ! wait_for_resource dpf-operator-system \
            dpunodes.provisioning.dpu.nvidia.com "dpu-node-${serial}" 60 10; then
            log [ERROR] "DPUNode dpu-node-${serial} was not discovered within 10 minutes"
            oc get dpudevices.provisioning.dpu.nvidia.com \
                -n dpf-operator-system || true
            return 1
        fi

        # Set the discovered DPUNode label to the empty value selected by DPUDeployment.
        log [INFO] "Normalizing the discovered DPUNode label for dpu-node-${serial}..."
        if ! oc label -n dpf-operator-system \
            "dpunode.provisioning.dpu.nvidia.com/dpu-node-${serial}" \
            feature.node.kubernetes.io/dpu-enabled= \
            --overwrite; then
            log [ERROR] "Failed to normalize the DPUNode label for dpu-node-${serial}"
            return 1
        fi

        if ! oc get "dpunode.provisioning.dpu.nvidia.com/dpu-node-${serial}" \
            -n dpf-operator-system -o json | \
            jq -e '.metadata.labels["feature.node.kubernetes.io/dpu-enabled"] == ""' \
                >/dev/null; then
            log [ERROR] "DPUNode dpu-node-${serial} does not have the required empty dpu-enabled label"
            return 1
        fi
    done < <(list_dpu_serial_variables)

    log [INFO] "Zero Trust DPU discovery completed"
    oc get dpudevices.provisioning.dpu.nvidia.com -n dpf-operator-system
    oc get dpunodes.provisioning.dpu.nvidia.com -n dpf-operator-system
}

function deploy_argocd() {
    log [INFO] "Deploying GitOps operator..."

    # Ensure kubeconfig is set and accessible
    get_kubeconfig

    if ! oc get subscription openshift-gitops-operator -n openshift-gitops-operator &>/dev/null; then
        log [INFO] "Installing GitOps operator..."
        mkdir -p "$GENERATED_DIR"
        process_template \
            "${MANIFESTS_DIR}/gitops-operator/subscription.yaml" \
            "$GENERATED_DIR/gitops-operator-subscription.yaml" \
            "<GITOPS_OPERATOR_CHANNEL>" "$GITOPS_OPERATOR_CHANNEL" \
            "<GITOPS_OPERATOR_VERSION>" "$GITOPS_OPERATOR_VERSION"
        apply_manifest "$GENERATED_DIR/gitops-operator-subscription.yaml"

        # Prefer CSV readiness over pod label matching for stability
        if ! retry 60 10 bash -c "oc get csv -n openshift-gitops-operator -o jsonpath='{.items[*].status.phase}' | grep -q Succeeded"; then
            log [ERROR] "Timeout: GitOps operator CSV did not reach Succeeded"
            return 1
        fi
    else
        log [INFO] "GitOps operator already exists."
    fi
    
    wait_for_pods "openshift-gitops-operator" "control-plane=gitops-operator" 60 10

    log [INFO] "Creating ArgoCD instance..."
    # Ensure target namespace exists before applying CR
    oc get ns dpf-operator-system &>/dev/null || oc create ns dpf-operator-system

    local argocd_manifest="${MANIFESTS_DIR}/gitops-operator/argocd.yaml"
    apply_manifest "${argocd_manifest}"
    wait_for_pods "dpf-operator-system" "app.kubernetes.io/name=argocd-application-controller" 60 10

    log [INFO] "GitOps operator deployment complete!"
}

function deploy_maintenance_operator() {
    log [INFO] "Deploying Maintenance Operator..."
    
    # Check if Maintenance Operator is already installed
    if check_helm_release_exists "dpf-operator-system" "maintenance-operator"; then
        log [INFO] "Skipping Maintenance Operator deployment."
        return 0
    fi
    
    # Ensure helm is installed
    ensure_helm_installed
    
    # Install Maintenance Operator
    log [INFO] "Installing Maintenance Operator chart..."
    helm upgrade --install maintenance-operator oci://ghcr.io/mellanox/maintenance-operator-chart \
        --namespace dpf-operator-system \
        --create-namespace \
        --disable-openapi-validation \
        --version ${MAINTENANCE_OPERATOR_VERSION} \
        --values "${HELM_CHARTS_DIR}/maintenance-operator-values.yaml" \
        --wait
    
    log [INFO] "Maintenance Operator deployment complete!"
}

function kube_apiserver_clusteroperator_condition_is() {
    local condition="$1"
    local expected="$2"
    local actual

    actual=$(oc get clusteroperator kube-apiserver \
        -o "jsonpath={.status.conditions[?(@.type==\"${condition}\")].status}" \
        2>/dev/null || true)
    [ "${actual}" = "${expected}" ]
}

function kube_apiserver_clusteroperator_is_healthy() {
    kube_apiserver_clusteroperator_condition_is Available True &&
        kube_apiserver_clusteroperator_condition_is Progressing False &&
        kube_apiserver_clusteroperator_condition_is Degraded False
}

function apply_zero_trust_bootstrap_auth() {
    [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ] || return 0

    local bootstrap_auth_patch="${MANIFESTS_DIR}/dpf-installation/zero-trust/kube-apiserver-bootstrap-auth.patch.yaml"
    local bootstrap_auth_enabled
    bootstrap_auth_enabled=$(oc get kubeapiserver cluster \
        -o 'jsonpath={.spec.unsupportedConfigOverrides.apiServerArguments.enable-bootstrap-token-auth[0]}' \
        2>/dev/null || true)

    if [ "${bootstrap_auth_enabled}" = "true" ]; then
        log "INFO" "Kube API bootstrap-token authentication is already enabled"
    else
        log "INFO" "Enabling kube-apiserver bootstrap-token authentication for Zero Trust DPU agents..."
        if [ ! -f "${bootstrap_auth_patch}" ]; then
            log "ERROR" "Kube API bootstrap-authentication patch not found: ${bootstrap_auth_patch}"
            return 1
        fi
        oc patch kubeapiserver cluster --type=merge \
            --patch-file "${bootstrap_auth_patch}"

        log "INFO" "Watching for the kube-apiserver rollout to start..."
        if ! retry 24 5 kube_apiserver_clusteroperator_condition_is Progressing True; then
            # A fast rollout can transition back to Progressing=False between
            # polls. The authoritative check below still requires the operator
            # to be Available and neither Progressing nor Degraded.
            log "WARN" "The kube-apiserver Progressing=True transition was not observed; checking final health"
        fi
    fi

    log "INFO" "Waiting for the kube-apiserver ClusterOperator to become healthy..."
    if ! retry 120 10 kube_apiserver_clusteroperator_is_healthy; then
        log "ERROR" "Kube-apiserver rollout did not complete successfully"
        oc get clusteroperator kube-apiserver
        return 1
    fi

    log "INFO" "Kube API bootstrap-token authentication is enabled and the rollout is complete"
}

function apply_dpf() {
    log "INFO" "Starting DPF deployment sequence..."
    log "INFO" "Provided kubeconfig ${KUBECONFIG}"
    log "INFO" "NFD deployment is $([ "${DISABLE_NFD}" = "true" ] && echo "disabled" || echo "enabled")"
    
    get_kubeconfig
    
    # Verify cluster is accessible before any deployments
    log "INFO" "Verifying cluster accessibility..."
    if ! oc cluster-info &>/dev/null; then
        log "ERROR" "Cluster is not accessible. Cannot proceed with DPF deployment."
        log "ERROR" "Please ensure the cluster is running and accessible."
        log "ERROR" "For SNO: Check if cluster VMs are running with: virsh list --all"
        return 1
    fi
    log "INFO" "Cluster is accessible, proceeding with DPF deployment..."

    deploy_argocd
    deploy_maintenance_operator

    if [ "${DPF_DEPLOYMENT_MODE}" != "zero-trust" ]; then
        log "INFO" "Enabling IP forwarding for OVN Kubernetes..."
        oc patch network.operator.openshift.io cluster --type=merge -p \
        '{"spec":{"defaultNetwork":{ "ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding":"Global"}}}}}'
    fi

    deploy_nfd
    apply_namespaces
    deploy_cert_manager

    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        deploy_metallb
        apply_zero_trust_bootstrap_auth
    fi
    
    # Install/upgrade DPF Operator using helm (idempotent operation)
    log "INFO" "Installing/upgrading DPF Operator to $DPF_VERSION..."
    
    # Validate DPF_VERSION is set
    if [ -z "$DPF_VERSION" ]; then
        log "ERROR" "DPF_VERSION is not set. Please set it in env.sh or as environment variable"
        return 1
    fi
    
    # Validate required DPF_PULL_SECRET exists
    if [ ! -f "$DPF_PULL_SECRET" ]; then
        log "ERROR" "DPF_PULL_SECRET file not found: $DPF_PULL_SECRET"
        log "ERROR" "Please ensure the pull secret file exists and contains valid NGC credentials"
        return 1
    fi
    
    # Authenticate helm with NGC registry using pull secret
    NGC_USERNAME=$(jq -r '.auths."nvcr.io".username // empty' "$DPF_PULL_SECRET" 2>/dev/null)
    NGC_PASSWORD=$(jq -r '.auths."nvcr.io".password // empty' "$DPF_PULL_SECRET" 2>/dev/null)
    
    # Validate credentials were extracted (check for empty or 'null' string)
    if [ -z "$NGC_USERNAME" ] || [ -z "$NGC_PASSWORD" ] || [ "$NGC_USERNAME" = "null" ] || [ "$NGC_PASSWORD" = "null" ]; then
        log "ERROR" "Failed to extract NGC credentials from pull secret. Please check the file format."
        return 1
    fi
    log "INFO" "Authenticating helm with NGC registry..."
    # Use stdin to avoid password in process list
    echo "$NGC_PASSWORD" | helm registry login nvcr.io --username "$NGC_USERNAME" --password-stdin >/dev/null 2>&1 || {
        log "ERROR" "Failed to authenticate with NGC registry. Please check your pull secret credentials."
        return 1
    }
    
    # Determine chart URL and args based on format
    if [[ "$DPF_HELM_REPO_URL" == oci://* ]]; then
        # OCI registry format (v25.7+)
        CHART_URL="${DPF_HELM_REPO_URL}/dpf-operator"
        HELM_ARGS="--version ${DPF_VERSION}"
    elif [[ "$DPF_HELM_REPO_URL" == *"helm.ngc.nvidia.com"* ]]; then
        # NGC Helm repository format (v25.7.1+)
        log "INFO" "Adding NGC Helm repository..."
        helm repo add nvidia-doca "${DPF_HELM_REPO_URL}" --force-update >/dev/null 2>&1 || {
            log "ERROR" "Failed to add NGC Helm repository"
            return 1
        }
        helm repo update nvidia-doca >/dev/null 2>&1 || {
            log "ERROR" "Failed to update NGC Helm repository index"
            return 1
        }
        CHART_URL="nvidia-doca/dpf-operator"
        HELM_ARGS="--version ${DPF_VERSION}"
    else
        # Legacy NGC format (v25.4 and older - direct .tgz URL)
        CHART_URL="${DPF_HELM_REPO_URL}-${DPF_VERSION}.tgz"
        HELM_ARGS=""
    fi

    # Install without --wait for immediate feedback
    if helm upgrade --install dpf-operator \
        "${CHART_URL}" \
        ${HELM_ARGS} \
        --namespace dpf-operator-system \
        --create-namespace \
        --disable-openapi-validation \
        --values "${HELM_CHARTS_DIR}/dpf-operator-values.yaml"; then
        
        log "INFO" "Helm release 'dpf-operator' deployed successfully"
        log "INFO" "DPF Operator deployment initiated. Use 'oc get pods -n dpf-operator-system' to monitor progress."
    else
        log "ERROR" "Helm deployment failed"
        return 1
    fi

    log [INFO] "Waiting for the DPF Operator before applying custom resources..."
    wait_for_pods "dpf-operator-system" "dpu.nvidia.com/component=dpf-operator-controller-manager" 60 5
    
    apply_remaining
    apply_scc
    deploy_hosted_cluster

    wait_for_pods "dpf-operator-system" "dpu.nvidia.com/component=dpf-operator-controller-manager" 30 5
    wait_for_dpf_provisioning_api
    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        zero_trust_dpu_discovery
    fi

    log [INFO] "DPF deployment complete"
}

function delete_dpf_hcp_provisioner_operator() {
    # Remove DPF HCP Provisioner Operator and all related resources
    log "INFO" "Removing DPF HCP Provisioner Operator..."

    get_kubeconfig

    # Ensure helm is installed
    ensure_helm_installed

    # Delete DPFHCPProvisioner CR instances (if any exist)
    log "INFO" "Deleting DPFHCPProvisioner custom resources..."
    if oc get dpfhcpprovisioner -n "${CLUSTERS_NAMESPACE}" &>/dev/null 2>&1; then
        if ! oc delete dpfhcpprovisioner --all -n "${CLUSTERS_NAMESPACE}" --ignore-not-found --timeout=600s; then
            log "ERROR" "Failed to delete DPFHCPProvisioner CRs. Exiting..."
            return 1
        fi
    else
        log "INFO" "No DPFHCPProvisioner CRs found in ${CLUSTERS_NAMESPACE}"
    fi

    # Delete DPFHCPProvisionerConfig CR (after provisioner CRs, before CRD)
    log "INFO" "Deleting DPFHCPProvisionerConfig CR..."
    if oc get dpfhcpprovisionerconfig default &>/dev/null 2>&1; then
        if ! oc delete dpfhcpprovisionerconfig default --ignore-not-found --timeout=60s; then
            log "ERROR" "Failed to delete DPFHCPProvisionerConfig CR. Exiting..."
            return 1
        fi
    else
        log "INFO" "No DPFHCPProvisionerConfig CR found"
    fi

    # Delete secrets created for DPFHCPProvisioner in clusters namespace
    log "INFO" "Deleting DPFHCPProvisioner secrets from ${CLUSTERS_NAMESPACE}..."
    oc delete secret -n "${CLUSTERS_NAMESPACE}" "${DPFHCPPROVISIONER_PULL_SECRET_NAME}" --ignore-not-found || {
        log "WARN" "Failed to delete secret ${DPFHCPPROVISIONER_PULL_SECRET_NAME} - it may not exist or there may be permission issues"
    }
    oc delete secret -n "${CLUSTERS_NAMESPACE}" "${DPFHCPPROVISIONER_SSH_SECRET_NAME}" --ignore-not-found || {
        log "WARN" "Failed to delete secret ${DPFHCPPROVISIONER_SSH_SECRET_NAME} - it may not exist or there may be permission issues"
    }

    # Uninstall helm release
    log "INFO" "Uninstalling DPF HCP Provisioner Operator helm release..."
    if helm list -n "${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE}" | grep -q "^dpf-hcp-provisioner-operator[[:space:]]"; then
        helm uninstall dpf-hcp-provisioner-operator -n "${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE}" --wait || {
            log "WARN" "Failed to uninstall helm release dpf-hcp-provisioner-operator"
        }
        log "INFO" "Helm release uninstalled successfully"
    else
        log "INFO" "Helm release dpf-hcp-provisioner-operator not found"
    fi

    # Delete the CRDs
    log "INFO" "Deleting DPFHCPProvisionerConfig CRD..."
    oc delete crd dpfhcpprovisionerconfigs.provisioning.dpu.hcp.io --ignore-not-found --timeout=600s || {
        log "WARN" "Failed to delete DPFHCPProvisionerConfig CRD, it may have finalizers or dependent resources"
    }
    log "INFO" "Deleting DPFHCPProvisioner CRD..."
    oc delete crd dpfhcpprovisioners.provisioning.dpu.hcp.io --ignore-not-found --timeout=600s || {
        log "WARN" "Failed to delete DPFHCPProvisioner CRD, it may have finalizers or dependent resources"
    }

    # Delete the operator namespace (helm uninstall does not delete namespaces)
    log "INFO" "Deleting DPF HCP Provisioner Operator namespace ${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE}..."
    if oc get namespace "${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE}" &>/dev/null 2>&1; then
        oc delete namespace "${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE}" --ignore-not-found --timeout=180s || {
            log "WARN" "Failed to delete namespace ${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE}, it may have finalizers or remaining resources"
        }
    else
        log "INFO" "Namespace ${DPF_HCP_PROVISIONER_OPERATOR_NAMESPACE} not found"
    fi

    log "INFO" "DPF HCP Provisioner Operator removal complete"
    log "INFO" "Note: The ${CLUSTERS_NAMESPACE} namespace was not deleted as it may contain other resources"
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
function main() {
    local command=$1
    shift

    log [INFO] "Executing command: $command"
    case "$command" in
            deploy-nfd)
                deploy_nfd
                ;;
            deploy-metallb)
                deploy_metallb
                ;;
            deploy-argocd)
                deploy_argocd
                ;;
            deploy-maintenance-operator)
                deploy_maintenance_operator
                ;;
            apply-dpf)
                apply_dpf
                ;;
            deploy-hypershift)
                deploy_hypershift
                ;;
            deploy-dpfhcp|deploy-dpf-hcp-provisioner-operator)
                deploy_dpfhcp
                ;;
            deploy-hosted-cluster)
                create_hosted_cluster
                ;;
            delete-dpf-hcp-provisioner-operator)
                delete_dpf_hcp_provisioner_operator
                ;;
            create-dpfhcpprovisioner-secrets)
                create_dpfhcpprovisioner_secrets
                ;;
            create-dpfhcpprovisioner-cr)
                create_dpfhcpprovisioner_cr
                ;;
            *)
                log [INFO] "Unknown command: $command"
                log [INFO] "Available commands: deploy-nfd, deploy-metallb, deploy-argocd, deploy-maintenance-operator, apply-dpf, deploy-hypershift, deploy-dpfhcp, deploy-hosted-cluster, deploy-dpf-hcp-provisioner-operator, delete-dpf-hcp-provisioner-operator, create-dpfhcpprovisioner-secrets, create-dpfhcpprovisioner-cr"
                exit 1
                ;;
        esac
}

# If script is executed directly (not sourced), run the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        log [INFO] "Usage: $0 <command> [arguments...]"
        exit 1
    fi
    
    main "$@"
fi
