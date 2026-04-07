#!/bin/bash
# manifests.sh - Manifest management operations

# Exit on error and catch pipe failures
set -e
set -o pipefail

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"

HOST_CLUSTER_API=${HOST_CLUSTER_API:-"api.$CLUSTER_NAME.$BASE_DOMAIN"}

# -----------------------------------------------------------------------------
# Manifest preparation functions
# -----------------------------------------------------------------------------
function prepare_manifests() {
    local manifest_type=$1
    log [INFO] "Preparing $manifest_type manifests..."
    
    # Clean and recreate generated directory
    rm -rf "$GENERATED_DIR"
    mkdir -p "$GENERATED_DIR"

    case "$manifest_type" in
        cluster)
            prepare_cluster_manifests
            ;;
        dpf)
            prepare_dpf_manifests
            ;;
        *)
            log [INFO] "Error: Unknown manifest type: $manifest_type"
            log [INFO] "Valid types are: cluster, dpf"
            exit 1
            ;;
    esac
}


function prepare_cluster_manifests() {
    log [INFO] "Preparing cluster installation manifests..."
    
    # Clean up any existing Helm values files that might have been left from previous runs
    find "$GENERATED_DIR" -maxdepth 1 -type f -name "*-values.yaml" -delete 2>/dev/null || true
    
    # Build list of files to exclude
    local excluded_files=(
        "ovn-values.yaml"
        "ovn-values-with-injector.yaml"
        "nfd-subscription.yaml"
        "99-worker-bridge.yaml"
    )

    if [ "${USE_V419_WORKAROUND}" != "true" ]; then
        excluded_files+=("4.19-cataloguesource.yaml")
    fi

    # Copy all manifests except excluded files using utility function
    copy_manifests_with_exclusions "$MANIFESTS_DIR/cluster-installation" "$GENERATED_DIR" "${excluded_files[@]}"

    # Process subscription manifests with catalog source name
    if [ -f "$MANIFESTS_DIR/cluster-installation/nfd-subscription.yaml" ]; then
        update_file_multi_replace \
            "$MANIFESTS_DIR/cluster-installation/nfd-subscription.yaml" \
            "$GENERATED_DIR/nfd-subscription.yaml" \
            "<CATALOG_SOURCE_NAME>" "$CATALOG_SOURCE_NAME"
    fi

    # Configure cluster components
    log [INFO] "Configuring cluster installation..."
    

    # Always copy Cert-Manager manifest (required for DPF operator)
    log [INFO] "Copying Cert-Manager manifest (required for DPF operator)..."
    cp "$MANIFESTS_DIR/cluster-installation/openshift-cert-manager.yaml" "$GENERATED_DIR/"

    # Verify no Helm values files are in the generated directory before proceeding
    if find "$GENERATED_DIR" -maxdepth 1 -type f -name "*-values.yaml" | grep -q .; then
        log "ERROR" "Helm values files found in generated directory during cluster installation. These should not be processed."
        find "$GENERATED_DIR" -maxdepth 1 -type f -name "*-values.yaml" -delete
        log "INFO" "Removed Helm values files from generated directory"
    fi


    enable_storage

    update_worker_manifest
    
    # Install manifests to cluster
    # Check if cluster is already installed
    if check_cluster_installed; then
        log [INFO] "Skipping manifest installation as cluster is already installed"
    else
        log [INFO] "Installing manifests to cluster via AICLI..."
        aicli create manifests --dir "$GENERATED_DIR" "$CLUSTER_NAME"

        # Upload openshift folder manifests (e.g., FeatureGate) to the openshift folder
        # This is needed to override built-in OpenShift manifests like 99_feature-gate.yaml
        local openshift_manifests_dir="$MANIFESTS_DIR/cluster-installation/openshift"
        if [ -d "$openshift_manifests_dir" ] && [ "$(ls -A "$openshift_manifests_dir" 2>/dev/null)" ]; then
            log [INFO] "Installing openshift folder manifests (to override built-in manifests)..."
            aicli create manifests --dir "$openshift_manifests_dir" --openshift "$CLUSTER_NAME"
        fi
    fi

    log [INFO] "Cluster manifests preparation complete."
}


update_worker_manifest() {

    local mtu=""
    if [ "${NODES_MTU}" != "1500" ]; then
        log "INFO" "Setting ExecStart to include MTU: ${NODES_MTU}"
        mtu="${NODES_MTU}"
    fi
    update_file_multi_replace \
            "$MANIFESTS_DIR/cluster-installation/99-worker-bridge.yaml" \
            "$GENERATED_DIR/99-worker-bridge.yaml" \
            "<NODES_MTU>" "$mtu"
}

function deploy_core_operator_sources() {
    log [INFO] "Deploying NFD and SR-IOV subscriptions..."
    log [INFO] "Using catalog source: ${CATALOG_SOURCE_NAME}"
    log [INFO] "Using v4.19 workaround: ${USE_V419_WORKAROUND}"

    mkdir -p "$GENERATED_DIR"

    update_file_multi_replace \
        "$MANIFESTS_DIR/cluster-installation/nfd-subscription.yaml" \
        "$GENERATED_DIR/nfd-subscription.yaml" \
        "<CATALOG_SOURCE_NAME>" "$CATALOG_SOURCE_NAME"
    apply_manifest "$GENERATED_DIR/nfd-subscription.yaml" true

    if [[ "${USE_V419_WORKAROUND}" == "true" ]]; then
        log [INFO] "Deploying v4.19 catalog source (workaround enabled)"
        local catalog_file="$MANIFESTS_DIR/cluster-installation/4.19-cataloguesource.yaml"
        if [ -f "$catalog_file" ]; then
            apply_manifest "$catalog_file" true
        fi
    else
        log [INFO] "Skipping v4.19 catalog source deployment (using standard OLM)"
    fi

    log [INFO] "Core operator sources deployed."
}

# Function to prepare DPF manifests
prepare_dpf_manifests() {
    log [INFO] "Starting DPF manifest preparation..."
    echo "Using manifests directory: ${MANIFESTS_DIR}"

    # Check required variables
    if [ -z "$MANIFESTS_DIR" ]; then
      echo "Error: MANIFESTS_DIR must be set"
      exit 1
    fi

    if [ -z "$GENERATED_DIR" ]; then
      echo "Error: GENERATED_DIR must be set"
      exit 1
    fi

    # Validate required variables
    if [ -z "$HOST_CLUSTER_API" ]; then
      echo "Error: HOST_CLUSTER_API must be set"
      exit 1
    fi


    # Create generated directory if it doesn't exist
    if [ ! -d "${GENERATED_DIR}" ]; then
        log "INFO" "Creating generated directory: ${GENERATED_DIR}"
        mkdir -p "${GENERATED_DIR}"
    fi

    # Copy and process manifests
    log "INFO" "Processing manifests from ${MANIFESTS_DIR} to ${GENERATED_DIR}"
    
    # Clean up any existing Helm values files that might have been left from previous runs
    find "$GENERATED_DIR" -maxdepth 1 -type f -name "*-values.yaml" -delete 2>/dev/null || true
    
    # Build list of files to exclude (all Helm values files)
    local excluded_files=(
        "*-values.yaml"
    )
    
    # Copy all manifests except Helm values files using utility function
    copy_manifests_with_exclusions "$MANIFESTS_DIR/dpf-installation" "$GENERATED_DIR" "${excluded_files[@]}"

    # Copy cert-manager manifest (required for DPF deployment)
    log "INFO" "Copying Cert-Manager manifest (required for DPF operator)..."
    cp "$MANIFESTS_DIR/cluster-installation/openshift-cert-manager.yaml" "$GENERATED_DIR/"

    update_file_multi_replace \
        "$GENERATED_DIR/static-dpucluster-template.yaml" \
        "$GENERATED_DIR/static-dpucluster-template.yaml" \
        "<KUBERNETES_VERSION>" "$OPENSHIFT_VERSION" \
        "<HOSTED_CLUSTER_NAME>" "$HOSTED_CLUSTER_NAME"

    # Extract NGC API key and update secrets
    NGC_API_KEY=$(jq -r '.auths."nvcr.io".password // empty' "$DPF_PULL_SECRET" 2>/dev/null)
    if [ -z "$NGC_API_KEY" ] || [ "$NGC_API_KEY" = "null" ]; then
        log "ERROR" "Failed to extract NGC API key from pull secret"
        return 1
    fi
    
    # Process ngc-secrets.yaml using process_template function
    update_file_multi_replace \
        "$MANIFESTS_DIR/dpf-installation/ngc-secrets.yaml" \
        "$GENERATED_DIR/ngc-secrets.yaml" \
        "<NGC_API_KEY>" "$NGC_API_KEY"

    # Update pull secret
    # Encode pull secret (Linux/GNU base64)
    PULL_SECRET=$(cat "$DPF_PULL_SECRET" | base64 -w 0)
    if [ -z "$PULL_SECRET" ]; then
        log "ERROR" "Failed to encode pull secret"
        return 1
    fi
    local escaped_secret=$(escape_sed_replacement "$PULL_SECRET")
    update_file_multi_replace \
        "$GENERATED_DIR/dpf-pull-secret.yaml" \
        "$GENERATED_DIR/dpf-pull-secret.yaml" \
        "<PULL_SECRET_BASE64>" "$escaped_secret"

    # Process dpfoperatorconfig.yaml
    # Get node IP for BFB registry address (workaround for hostagent DNSPolicy:Default)
    local node_ip
    node_ip=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    if [ -z "$node_ip" ]; then
        log "ERROR" "Failed to get node InternalIP for BFB registry address"
        return 1
    fi
    local bfb_registry_address="http://${node_ip}:30082"
    log "INFO" "Setting BFB registry address to ${bfb_registry_address}"

    update_file_multi_replace \
        "$MANIFESTS_DIR/dpf-installation/dpfoperatorconfig.yaml" \
        "$GENERATED_DIR/dpfoperatorconfig.yaml" \
        "<CLUSTER_NAME>" "$CLUSTER_NAME" \
        "<BASE_DOMAIN>" "$BASE_DOMAIN" \
        "<BFB_REGISTRY_ADDRESS>" "$bfb_registry_address" \
        "<SRIOV_DP_RESOURCE_PREFIX>" "$SRIOV_DP_RESOURCE_PREFIX"
    
    # For OCP >= 4.22, Hypershift handles node CIDR allocation natively so
    # the dpu-node-ipam-controller is not deployed.  Instead, tell DPF's
    # Flannel the cluster CIDR that the provisioner operator configures on
    # the HostedCluster.
    local flannel_config=""
    if ocp_version_gte "${OPENSHIFT_VERSION}" "4.22"; then
        log "INFO" "OCP ${OPENSHIFT_VERSION} >= 4.22: setting flannel podCIDR to ${FLANNEL_POD_CIDR}"
        flannel_config="flannel:
    podCIDR: ${FLANNEL_POD_CIDR}"
    fi
    update_file_multi_replace \
        "$GENERATED_DIR/dpfoperatorconfig.yaml" \
        "$GENERATED_DIR/dpfoperatorconfig.yaml" \
        "<FLANNEL_CONFIG>" "$flannel_config"

    if [ -n "$NODES_MTU" ] && [ "$NODES_MTU" == "9000" ]; then
        log "INFO" "Appending networking configuration with MTU: $NODES_MTU"
        cat >> "$GENERATED_DIR/dpfoperatorconfig.yaml" <<-EOF
  networking:
    controlPlaneMTU: $NODES_MTU
    highSpeedMTU: $NODES_MTU
EOF
    else
       log "INFO" "NODES_MTU is not set. Skipping networking configuration."
    fi

    # Final verification: ensure no Helm values files are in the generated directory
    if find "$GENERATED_DIR" -maxdepth 1 -type f -name "*-values.yaml" | grep -q .; then
        log "ERROR" "Helm values files found in generated directory. These should not be processed during cluster installation."
        find "$GENERATED_DIR" -maxdepth 1 -type f -name "*-values.yaml" -delete
        log "INFO" "Removed Helm values files from generated directory"
    fi

    log "INFO" "DPF manifest preparation completed successfully"
}

function update_ovn_mtu_in_value_file() {
    local ovn_values_file=$1

    if [ -z "$ovn_values_file" ] || [ ! -f "$ovn_values_file" ]; then 
       log "ERROR" "OVN values file not found: ${ovn_values_file}" 
       return 1
    fi
    # Check if NODES_MTU is defined and is not 1500
    if [[ -n "$NODES_MTU" ]] && [[ "$NODES_MTU" != "1500" ]]; then
        echo "NODES_MTU is defined as $NODES_MTU. Updating MTU in $ovn_values_file."

        local new_mtu=$((NODES_MTU - 60))
        if grep -Eq '^[[:space:]]*mtu:' "$ovn_values_file"; then
           sed -i "s/mtu:.*/mtu: $new_mtu/" "$ovn_values_file"
        else
           sed -i "/podNetwork:/a\mtu: $new_mtu" "$ovn_values_file"
        fi
        echo "Successfully updated MTU to $new_mtu in $ovn_values_file."
    else
        echo "NODES_MTU is not defined or is 1500. Setting default MTU to 1400 in $ovn_values_file."
        local new_mtu=1400

        if grep -Eq '^[[:space:]]*mtu:' "$ovn_values_file"; then
            sed -i "s/mtu:.*/mtu: $new_mtu/" "$ovn_values_file"
        else
            sed -i "/podNetwork:/a\mtu: $new_mtu" "$ovn_values_file"
        fi
        echo "Successfully set default MTU to $new_mtu in $ovn_values_file." 
    fi
}

# Not used anymore
# Saving it for possible future use
function generate_ovn_manifests() {
    log [INFO] "Generating OVN manifests for cluster installation..."
    
    # NOTE: We must use helm template here because these manifests are added to the cluster
    # via 'aicli create manifests' before the cluster API is available for helm install
    
    # Validate DPF_VERSION is set
    if [ -z "$DPF_VERSION" ]; then
        log [ERROR] "DPF_VERSION is not set. Required for OVN chart pull"
        return 1
    fi
    
    # Ensure helm is installed
    ensure_helm_installed
    
    mkdir -p "$GENERATED_DIR/temp"
    local API_SERVER="api.$CLUSTER_NAME.$BASE_DOMAIN:6443"
    
    # Pull and template OVN chart
    log [INFO] "Pulling OVN chart ${OVN_CHART_VERSION}..."
    if ! helm pull "${OVN_CHART_URL}/ovn-kubernetes-chart" \
        --version "${OVN_CHART_VERSION}" \
        --untar -d "$GENERATED_DIR/temp"; then
        log [ERROR] "Failed to pull OVN chart ${DPF_VERSION}"
        return 1
    fi
    
    update_ovn_mtu_in_value_file $HELM_CHARTS_DIR/ovn-values.yaml
    
    # Replace template variables in values file
    sed -e "s|<TARGETCLUSTER_API_SERVER_HOST>|api.$CLUSTER_NAME.$BASE_DOMAIN|" \
        -e "s|<TARGETCLUSTER_API_SERVER_PORT>|6443|" \
        -e "s|<POD_CIDR>|$POD_CIDR|" \
        -e "s|<SERVICE_CIDR>|$SERVICE_CIDR|" \
        -e "s|<OVN_KUBERNETES_IMAGE_REPO>|$OVN_KUBERNETES_IMAGE_REPO|" \
        -e "s|<OVN_KUBERNETES_IMAGE_TAG>|$OVN_KUBERNETES_IMAGE_TAG|" \
        -e "s|<OVN_KUBERNETES_UTILS_IMAGE_REPO>|$OVN_KUBERNETES_UTILS_IMAGE_REPO|" \
        -e "s|<OVN_KUBERNETES_UTILS_IMAGE_TAG>|$OVN_KUBERNETES_UTILS_IMAGE_TAG|" \
        "$HELM_CHARTS_DIR/ovn-values.yaml" > "$GENERATED_DIR/temp/ovn-values-resolved.yaml"
    
    log [INFO] "Generating OVN manifests from helm template..."
    if ! helm template -n ${OVNK_NAMESPACE} ovn-kubernetes \
        "$GENERATED_DIR/temp/ovn-kubernetes-chart" \
        -f "$GENERATED_DIR/temp/ovn-values-resolved.yaml" \
        > "$GENERATED_DIR/ovn-manifests.yaml"; then
        log [ERROR] "Failed to generate OVN manifests"
        return 1
    fi
    
    # Check if the file is not empty
    if [ ! -s "$GENERATED_DIR/ovn-manifests.yaml" ]; then
        log [ERROR] "Generated OVN manifest file is empty!"
        return 1
    fi
    
    rm -rf "$GENERATED_DIR/temp"
    
    log [INFO] "OVN manifests generated successfully"
}

function enable_storage() {
    log [INFO] "Enabling storage operator (STORAGE_TYPE=${STORAGE_TYPE})"

    # Skip when user provides their own StorageClasses
    if [ "${SKIP_DEPLOY_STORAGE}" = "true" ]; then
        log [INFO] "SKIP_DEPLOY_STORAGE=true: not enabling LSO/LVM operator; using existing StorageClasses (ETCD_STORAGE_CLASS=${ETCD_STORAGE_CLASS})"
        return 0
    fi

    # Check if cluster is already installed
    if check_cluster_installed; then
        log [INFO] "Skipping storage operator configuration as cluster is already installed"
        return 0
    fi

    if [ "${STORAGE_TYPE}" == "odf" ]; then
        log [INFO] "Enable LSO operator via assisted installer OLM (ODF will be deployed post-install)"
        aicli update cluster "$CLUSTER_NAME" -P olm_operators='[{"name": "lso"}]'
    else
        log [INFO] "Enable LVM operator via assisted installer OLM"
        aicli update cluster "$CLUSTER_NAME" -P olm_operators='[{"name": "lvm"}]'
    fi
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
function main() {
    local command=$1
    shift

    case "$command" in
        deploy-core-operator-sources)
            deploy_core_operator_sources
            ;;
        generate-ovn-manifests)
            generate_ovn_manifests
            ;;
        prepare-manifests)
            prepare_manifests "cluster"
            ;;
        prepare-dpf-manifests)
            prepare_manifests "dpf"
            ;;
        apply-lso)
            deploy_lso
            ;;
        *)
            log [INFO] "Unknown command: $command"
            log [INFO] "Available commands: prepare-manifests, prepare-dpf-manifests, apply-lso, deploy-core-operator-sources, generate-ovn-manifests"
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

