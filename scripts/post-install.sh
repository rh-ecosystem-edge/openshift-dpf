#!/bin/bash
# post-install.sh - Prepare and apply post-installation manifests to the cluster

# Exit on error and catch pipe failures
set -e
set -o pipefail

# Source common utilities and configuration
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"

# Configuration
MANIFESTS_DIR=${MANIFESTS_DIR:-"manifests"}
POST_INSTALL_DIR="${MANIFESTS_DIR}/post-installation"
GENERATED_DIR=${GENERATED_DIR:-"$MANIFESTS_DIR/generated"}
GENERATED_POST_INSTALL_DIR="${GENERATED_DIR}/post-install"

# BFB Configuration with defaults
BFB_URL=${BFB_URL:-"http://10.8.2.236/bfb/rhcos_4.19.0-ec.4_installer_2025-04-23_07-48-42.bfb"}

# HBN OVN Configuration with defaults
HBN_OVN_NETWORK=${HBN_OVN_NETWORK:-"10.0.120.0/22"}

# Ensure directories exist
mkdir -p "${GENERATED_POST_INSTALL_DIR}"

# List of files that need special processing (excluded from direct copy)
SPECIAL_FILES=(
    "bfb.yaml"
    "hbn-ovn-ipam.yaml"
    "dpu-service-nads.yaml"
    "dpuflavor-1500.yaml"
    "dpuflavor-9000.yaml"
    "dpuflavor.yaml"
    "ovn-template.yaml"
    "ovn-configuration.yaml"
    "hbn-template.yaml"
    "hbn-configuration.yaml"
    "dts-template.yaml"
    "blueman-template.yaml"
    "dpu-node-ipam-controller.yaml"
    "dpudeployment.yaml"
)

# Function to update BFB manifest
function update_bfb_manifest() {
    log [INFO] "Updating BFB manifest..."
    # Extract filename from URL
    local bfb_filename=$(basename "${BFB_URL}")
    # Update the manifest with custom values using update_file_multi_replace
    update_file_multi_replace \
        "${POST_INSTALL_DIR}/bfb.yaml" \
        "${GENERATED_POST_INSTALL_DIR}/bfb.yaml" \
        "<BFB_FILENAME>" "${bfb_filename}" \
        "<BFB_URL>" "\"${BFB_URL}\""
    log [INFO] "BFB manifest updated successfully"
}

# Function to update HBN OVN manifests
function update_hbn_ovn_manifests() {
    log [INFO] "Updating HBN OVN manifests..."
    
    # DPU_HOST_CIDR must be set by user
    if [ -z "${DPU_HOST_CIDR}" ]; then
        log [ERROR] "DPU_HOST_CIDR environment variable is not set. Please set it to the DPU nodes subnet (e.g., 10.6.135.0/24)"
        return 1
    fi
    # Update hbn-ovn-ipam.yaml
    update_file_multi_replace \
        "${POST_INSTALL_DIR}/hbn-ovn-ipam.yaml" \
        "${GENERATED_POST_INSTALL_DIR}/hbn-ovn-ipam.yaml" \
        "<HBN_OVN_NETWORK>" \
        "${HBN_OVN_NETWORK}"
    
    # Skip ovn-dpuservice.yaml - now handled by DPUDeployment
    # Services are now managed through DPUDeployment with templates and configurations
    
    # Update ovn-template.yaml for DPUDeployment
    if [ -f "${POST_INSTALL_DIR}/ovn-template.yaml" ]; then
        # Determine the replacement value for <OVN_KUBERNETES_UTILS_IMAGES>
        local utils_images_replacement=""
        if [ -n "${OVN_KUBERNETES_UTILS_IMAGE_REPO}" ] && [ -n "${OVN_KUBERNETES_UTILS_IMAGE_TAG}" ]; then
            # Build the imagedpf block with proper indentation (8 spaces for imagedpf:, 10 spaces for repository/tag)
            utils_images_replacement="imagedpf:
          repository: ${OVN_KUBERNETES_UTILS_IMAGE_REPO}
          tag: ${OVN_KUBERNETES_UTILS_IMAGE_TAG}"
            log [INFO] "OVN_KUBERNETES_UTILS_IMAGE_REPO and OVN_KUBERNETES_UTILS_IMAGE_TAG set, including imagedpf section in ovn-template.yaml" 
        else
            log [INFO] "OVN_KUBERNETES_UTILS_IMAGE_REPO or OVN_KUBERNETES_UTILS_IMAGE_TAG not set, omitting imagedpf section from ovn-template.yaml"
        fi
        
        # Use update_file_multi_replace for all replacements
        update_file_multi_replace \
            "${POST_INSTALL_DIR}/ovn-template.yaml" \
            "${GENERATED_POST_INSTALL_DIR}/ovn-template.yaml" \
            "<DPF_VERSION>" "${DPF_VERSION}" \
            "<OVN_CHART_VERSION>" "${OVN_CHART_VERSION}" \
            "<OVN_TEMPLATE_CHART_URL>" "${OVN_TEMPLATE_CHART_URL}" \
            "<OVN_KUBERNETES_IMAGE_REPO>" "${OVN_KUBERNETES_IMAGE_REPO}" \
            "<OVN_KUBERNETES_IMAGE_TAG>" "${OVN_KUBERNETES_IMAGE_TAG}" \
            "<OVN_KUBERNETES_UTILS_IMAGES>" "${utils_images_replacement}" \
            "<OVN_CHART_URL>" "${OVN_CHART_URL}"
    fi

    # Update ovn-configuration.yaml for DPUDeployment
    if [ -f "${POST_INSTALL_DIR}/ovn-configuration.yaml" ]; then
        local ovn_mtu=""

        if [ "$NODES_MTU" != "1500" ]; then
            ovn_mtu=$((NODES_MTU - 60))
        else
            ovn_mtu=1400
        fi
        log "INFO" "ovn-configuration will be set with MTU:$ovn_mtu"
        update_file_multi_replace \
            "${POST_INSTALL_DIR}/ovn-configuration.yaml" \
            "${GENERATED_POST_INSTALL_DIR}/ovn-configuration.yaml" \
            "<HBN_OVN_NETWORK>" "${HBN_OVN_NETWORK}" \
            "<HOST_CLUSTER_API>" "${HOST_CLUSTER_API}" \
            "<DPU_HOST_CIDR>" "${DPU_HOST_CIDR}" \
            "<NODES_MTU>" "${ovn_mtu}"
    fi
    
    # Update hbn-configuration.yaml 
    if [ -f "${POST_INSTALL_DIR}/hbn-configuration.yaml" ]; then
        update_file_multi_replace \
            "${POST_INSTALL_DIR}/hbn-configuration.yaml" \
            "${GENERATED_POST_INSTALL_DIR}/hbn-configuration.yaml"
    fi

    log [INFO] "HBN OVN manifests updated successfully"
}

# Function to update VF configuration
function update_vf_configuration() {
    log [INFO] "Updating VF configuration in manifests..."
    
    # Calculate VF range upper bound
    local vf_range_upper=$((NUM_VFS - 1))

    if [ "$NODES_MTU" == "1500" ]; then
        mtu_source_file="dpuflavor-1500.yaml"
    else
        mtu_source_file="dpuflavor-9000.yaml"
    fi

    log "INFO" "Creating unified dpuflavor.yaml from $mtu_source_file for MTU $NODES_MTU"
    
    # Copy and process the appropriate source file as dpuflavor.yaml
    update_file_multi_replace \
        "${POST_INSTALL_DIR}/$mtu_source_file" \
        "${GENERATED_POST_INSTALL_DIR}/dpuflavor.yaml" \
        "<NUM_VFS>" "${NUM_VFS}"
    
    
    log [INFO] "VF configuration updated successfully"
}

# Function to update service template versions
function update_service_templates() {
    log [INFO] "Updating service template versions..."
    
    # Validate DPF_VERSION is set
    if [ -z "$DPF_VERSION" ]; then
        log [ERROR] "DPF_VERSION is not set. Required for service template updates"
        return 1
    fi
    
    # Update all service templates with DPF_VERSION if they exist
    local templates=("hbn-template.yaml" "dts-template.yaml" "blueman-template.yaml")
    
    for template in "${templates[@]}"; do
        if [ -f "${POST_INSTALL_DIR}/${template}" ]; then
            # HBN template needs helm repo URL, version, and image configuration
            if [[ "${template}" == "hbn-template.yaml" ]]; then
                update_file_multi_replace \
                    "${POST_INSTALL_DIR}/${template}" \
                    "${GENERATED_POST_INSTALL_DIR}/${template}" \
                    "<HBN_HELM_REPO_URL>" "${HBN_HELM_REPO_URL}" \
                    "<HBN_HELM_CHART_VERSION>" "${HBN_HELM_CHART_VERSION}" \
                    "<HBN_IMAGE_REPO>" "${HBN_IMAGE_REPO}" \
                    "<HBN_IMAGE_TAG>" "${HBN_IMAGE_TAG}"
                log [INFO] "Updated ${template} with HBN helm and image configuration"
            # DTS template needs helm repo URL and version
            elif [[ "${template}" == "dts-template.yaml" ]]; then
                update_file_multi_replace \
                    "${POST_INSTALL_DIR}/${template}" \
                    "${GENERATED_POST_INSTALL_DIR}/${template}" \
                    "<DTS_HELM_REPO_URL>" "${DTS_HELM_REPO_URL}" \
                    "<DTS_HELM_CHART_VERSION>" "${DTS_HELM_CHART_VERSION}"
                log [INFO] "Updated ${template} with DTS helm configuration"
            else
                update_file_multi_replace \
                    "${POST_INSTALL_DIR}/${template}" \
                    "${GENERATED_POST_INSTALL_DIR}/${template}" \
                    "<DPF_VERSION>" "${DPF_VERSION}"
                log [INFO] "Updated ${template} with DPF_VERSION"
            fi
        fi
    done
    
    # Update IPAM controller manifest
    if [ -f "${POST_INSTALL_DIR}/dpu-node-ipam-controller.yaml" ]; then
        update_file_multi_replace \
            "${POST_INSTALL_DIR}/dpu-node-ipam-controller.yaml" \
            "${GENERATED_POST_INSTALL_DIR}/dpu-node-ipam-controller.yaml" \
            "<HOSTED_CONTROL_PLANE_NAMESPACE>" "${HOSTED_CONTROL_PLANE_NAMESPACE}" \
            "<HOSTED_CLUSTER_NAME>" "${HOSTED_CLUSTER_NAME}"
        log [INFO] "Updated dpu-node-ipam-controller.yaml with namespace and cluster name"
    fi
    
    log [INFO] "Service template versions updated successfully"
}



function update_dpu_service_nad() {
   local svc_file="dpu-service-nads.yaml" 

   if [ -f "${POST_INSTALL_DIR}/${svc_file}" ]; then
       update_file_multi_replace \
         "${POST_INSTALL_DIR}/${svc_file}" \
         "${GENERATED_POST_INSTALL_DIR}/${svc_file}" \
         "<SVC_MTU>" "${NODES_MTU}"
   fi

   log [INFO] "Updated ${svc_file} with MTU: ${NODES_MTU}"
}

# Function to prepare post-installation manifests
function prepare_post_installation() {
    log [INFO] "Starting post-installation manifest preparation..."
    
    # Check if post-installation directory exists
    if [ ! -d "${POST_INSTALL_DIR}" ]; then
        log [ERROR] "Post-installation directory not found: ${POST_INSTALL_DIR}"
        exit 1
    fi
    # Update manifests with custom values
    update_bfb_manifest
    update_hbn_ovn_manifests
    update_vf_configuration
    update_service_templates
    update_dpu_service_nad
    
    # Copy DPUDeployment
    if [ -f "${POST_INSTALL_DIR}/dpudeployment.yaml" ]; then
        cp "${POST_INSTALL_DIR}/dpudeployment.yaml" "${GENERATED_POST_INSTALL_DIR}/dpudeployment.yaml"
    fi

    # Copy remaining manifests using utility function (exclude special files)
    copy_manifests_with_exclusions "${POST_INSTALL_DIR}" "${GENERATED_POST_INSTALL_DIR}" "${SPECIAL_FILES[@]}"
    
    log [INFO] "Post-installation manifest preparation completed successfully"
}

# Function to apply post-installation manifests
function apply_post_installation() {
    log [INFO] "Starting post-installation manifest application..."
    
    # Check if generated post-installation directory exists
    if [ ! -d "${GENERATED_POST_INSTALL_DIR}" ]; then
        log [ERROR] "Generated post-installation directory not found: ${GENERATED_POST_INSTALL_DIR}"
        log [ERROR] "Please run prepare-dpu-files first"
        exit 1
    fi
    
    # Get kubeconfig
    get_kubeconfig
    
    # Wait for DPF provisioning webhook to be ready before applying manifests
    log [INFO] "Waiting for DPF provisioning webhook service to be ready..."
    local webhook_ready=false
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ] && [ "$webhook_ready" = "false" ]; do
        attempt=$((attempt + 1))
        
        # Check if webhook endpoints are available
        if oc get endpoints -n dpf-operator-system dpf-provisioning-webhook-service -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; then
            log [INFO] "DPF provisioning webhook service is ready"
            webhook_ready=true
        else
            if [ $attempt -eq 1 ]; then
                log [INFO] "Waiting for webhook endpoints to be available..."
            fi
            sleep 5
        fi
    done
    
    if [ "$webhook_ready" = "false" ]; then
        log [ERROR] "DPF provisioning webhook service not ready after $max_attempts attempts"
        log [ERROR] "This may cause failures when applying DPU manifests that require webhook validation"
        # Check if we should fail or continue based on environment variable
        if [ "${STRICT_WEBHOOK_CHECK:-true}" = "true" ]; then
            return 1
        else
            log [WARN] "STRICT_WEBHOOK_CHECK is disabled, proceeding anyway..."
        fi
    fi
    
    # Apply each YAML file in the generated post-installation directory
    for file in "${GENERATED_POST_INSTALL_DIR}"/*.yaml; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            # Skip dpudeployment.yaml as it will be applied last
            if [[ "${filename}" != "dpudeployment.yaml" ]]; then
                # Special handling for SCC - must be applied to hosted cluster
                if [[ "${filename}" == "dpu-services-scc.yaml" ]] && [[ -f "${HOSTED_CLUSTER_NAME}.kubeconfig" ]]; then
                    log [INFO] "Applying SCC to hosted cluster: ${filename}"
                    local saved_kubeconfig="${KUBECONFIG}"
                    export KUBECONFIG="${HOSTED_CLUSTER_NAME}.kubeconfig"
                    apply_manifest "$file" "true"
                    export KUBECONFIG="${saved_kubeconfig}"
                else
                    log [INFO] "Applying post-installation manifest: ${filename}"
                    apply_manifest "$file" "true"
                fi
            fi
        fi
    done
    
    # Apply dpudeployment.yaml last if it exists, with apply_always=true
    if [ -f "${GENERATED_POST_INSTALL_DIR}/dpudeployment.yaml" ]; then
        log [INFO] "Applying dpudeployment.yaml (last manifest)..."
        apply_manifest "${GENERATED_POST_INSTALL_DIR}/dpudeployment.yaml" "true"
    else
        log [WARN] "dpudeployment.yaml not found in ${GENERATED_POST_INSTALL_DIR}"
    fi
    
    log [INFO] "Post-installation manifest application completed successfully"
}

function redeploy() {
    log [INFO] "Redeploying DPU..."
    prepare_post_installation

    log [INFO] "Deleting existing manifests..."
    oc delete -f "${GENERATED_POST_INSTALL_DIR}/dpudeployment.yaml" || true
    oc delete -f "${GENERATED_POST_INSTALL_DIR}/bfb.yaml" || true

    # wait till all dpu are removed
    if ! retry 60 5 oc wait --for=delete dpu -A --all; then
        log [ERROR] "Failed to wait for DPU deletion"
        return 1
    fi

    oc delete -f "${GENERATED_POST_INSTALL_DIR}/dpuflavor.yaml" || true

    apply_post_installation

}

# If script is executed directly (not sourced), run the appropriate function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        log [ERROR] "Usage: $0 <prepare|apply|redeploy>"
        exit 1
    fi
    
    case "$1" in
        prepare)
            prepare_post_installation
            ;;
        apply)
            apply_post_installation
            ;;
        redeploy)
            redeploy
            ;;
        *)
            log [ERROR] "Unknown command: $1"
            log [ERROR] "Available commands: prepare, apply, redeploy"
            exit 1
            ;;
    esac
fi
