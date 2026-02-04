#!/bin/bash
# cluster.sh - Cluster management operations for OpenShift DPF
#
# This file contains functions for managing OpenShift clusters and ISO images.
# ISO handling is implemented with a minimal, single-function approach:
#   - get_iso: Universal function for master/worker ISO operations (URL or download)
#
# Key features:
# - InfraEnv approach for token-based URLs (required for authentication)
# - Fallback to console.redhat.com UI if direct method fails
# - Special handling for token-based URLs to preserve authentication
# - Support for both minimal and full ISO types

# Exit on error and catch pipe failures
set -e
set -o pipefail

# Source environment variables
source "$(dirname "$0")/env.sh"

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/update-etc-hosts.sh"

function validate_vips() {
    if [ -z "${API_VIP}" ] || [ "${API_VIP}" = "[]" ]; then
        log "ERROR" "API_VIPS is not set or invalid. Please provide a valid API_VIP."
        exit 1
    fi

    if [ -z "${INGRESS_VIP}" ] || [ "${INGRESS_VIP}" = "[]" ]; then
        log "ERROR" "INGRESS_VIPS is not set or invalid. Please provide a valid INGRESS_VIP."
        exit 1
    fi
    # Validate API_VIP and INGRESS_VIP
    if is_valid_ip "${API_VIP}"; then
        export API_VIPS="[${API_VIP}]"
    else
        log "ERROR" "Invalid API_VIP: ${API_VIP}"
        exit 1
    fi

    # Construct INGRESS_VIPS
    if is_valid_ip "${INGRESS_VIP}"; then
        export INGRESS_VIPS="[${INGRESS_VIP}]"
    else
        log "ERROR" "Invalid INGRESS_VIP: ${INGRESS_VIP}"
        exit 1
    fi
}

function is_valid_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || $ip =~ ^([0-9a-fA-F]*:[0-9a-fA-F]*){2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Cluster management functions
# -----------------------------------------------------------------------------
function check_cluster_installed() {
    log "INFO" "Checking if cluster ${CLUSTER_NAME} is installed..."
    
    # When multiple clusters exist with same name, we need to check if ANY has status "installed"
    # This handles the case where day2 cluster exists alongside the main cluster
    local installed_found=false
    
    # Get all clusters with this name and check their status
    while IFS= read -r cluster_id; do
        if [ -n "$cluster_id" ]; then
            local status=$(aicli info cluster "$cluster_id" -f status -v 2>/dev/null || echo "unknown")
            if [ "$status" = "installed" ]; then
                log "INFO" "Found installed cluster ${CLUSTER_NAME} (ID: $cluster_id)"
                installed_found=true
                break
            fi
        fi
    done < <(aicli list clusters | grep "^| *${CLUSTER_NAME} *|" | awk -F'|' '{print $3}' | tr -d ' ')
    
    if [ "$installed_found" = "true" ]; then
        return 0
    fi
    
    return 1
}

function set_cluster_mtu() {
    if ! [[ "$NODES_MTU" =~ ^[0-9]+$ ]]; then
          log "ERROR" "NODES_MTU must be a positive integer, got: $NODES_MTU"
          return 1
    fi
    if [ -f "$STATIC_NET_FILE" ]; then
        rm "$STATIC_NET_FILE"
    fi
    echo "static_network_config:" >> "$STATIC_NET_FILE"

    for i in $(seq 1 "$VM_COUNT"); do
        VM_NAME="${VM_PREFIX}${i}"

        # Use machine-id based MAC (default)
        if ! UNIQUE_MAC=$(generate_mac_from_machine_id "$VM_NAME"); then
            log "ERROR" "Failed to generate MAC for $VM_NAME"
            return 1
        fi

        log "INFO" "Set MAC: $UNIQUE_MAC ,Will be set on VM: $VM_NAME"

        cat << EOF >> "$STATIC_NET_FILE"
        - interfaces: 
           - name: ${PRIMARY_IFACE:-enp1s0}
             type: ethernet
             state: up
             mtu: ${NODES_MTU}
             mac-address: '${UNIQUE_MAC}'
             ipv4:
               dhcp: true
               enabled: true
EOF
    done
}

function check_create_cluster() {
    log "INFO" "Checking if cluster ${CLUSTER_NAME} exists..."
    
    # First check if cluster is already installed
    if check_cluster_installed; then
        log "INFO" "Cluster is already installed, skipping creation"
        return 0
    fi

    if [ "${NODES_MTU}" != "1500" ] ; then
       set_cluster_mtu || return 1
    fi

    if ! aicli info cluster ${CLUSTER_NAME} >/dev/null 2>&1; then
        log "INFO" "Cluster ${CLUSTER_NAME} not found, creating..."

        if [ "$VM_COUNT" -eq 1 ]; then
            log "INFO" "Creating single-node cluster..."
            aicli create cluster \
                -P openshift_version="${OPENSHIFT_VERSION}" \
                -P base_dns_domain="${BASE_DOMAIN}" \
                -P pull_secret="${OPENSHIFT_PULL_SECRET}" \
                -P high_availability_mode=None \
                -P user_managed_networking=True \
		        $([ "${NODES_MTU}" != "1500" ] && echo "--paramfile ${STATIC_NET_FILE}") \
                "${CLUSTER_NAME}"
        else
            log "INFO" "Creating multi-node cluster..."
            validate_vips
            echo "API_VIPS: ${API_VIPS}"
            echo "INGRESS_VIPS: ${INGRESS_VIPS}"
            aicli create cluster \
                -P openshift_version="${OPENSHIFT_VERSION}" \
                -P base_dns_domain="${BASE_DOMAIN}" \
                -P api_vips="${API_VIPS}" \
                -P pull_secret="${OPENSHIFT_PULL_SECRET}" \
                -P public_key="${SSH_KEY}" \
                -P ingress_vips="${INGRESS_VIPS}" \
		        $([ "${NODES_MTU}" != "1500" ] && echo "--paramfile ${STATIC_NET_FILE}") \
                "${CLUSTER_NAME}"
        fi
        
        log "INFO" "Cluster ${CLUSTER_NAME} created successfully"
    else
        log "INFO" "Cluster ${CLUSTER_NAME} already exists"
    fi
}

function delete_cluster() {
    log "INFO" "Deleting cluster ${CLUSTER_NAME}..."
    if ! aicli delete cluster ${CLUSTER_NAME} -y; then
        log "WARNING" "Failed to delete cluster ${CLUSTER_NAME}, continuing anyway"
    else
        log "INFO" "Cluster ${CLUSTER_NAME} deleted successfully"
    fi
}

function wait_for_cluster_status() {
    local status=$1
    local max_retries=${2:-120}
    local sleep_time=${3:-60}
    local retries=0
    
    log "INFO" "Waiting for cluster ${CLUSTER_NAME} to reach status: ${status}"
    while [ $retries -lt $max_retries ]; do
        # Capture aicli output, handle potential failures
        if ! current_status=$(aicli info cluster "$CLUSTER_NAME" -f status -v 2>/dev/null); then
            log "WARN" "Failed to get cluster status (attempt $((retries + 1))/${max_retries})"
            retries=$((retries + 1))
            sleep $sleep_time
            continue
        fi
        # If waiting for 'ready' but status is already 'installed', treat as success
        if [ "$status" == "ready" ] && [ "$current_status" == "installed" ]; then
            log "INFO" "Cluster ${CLUSTER_NAME} is already installed. Skipping wait for 'ready'."
            return 0
        fi
        if [ "$current_status" == "$status" ]; then
            log "INFO" "Cluster ${CLUSTER_NAME} reached status: ${status}"
            return 0
        fi
        log "DEBUG" "Attempt $retries of $MAX_RETRIES. Waiting $SLEEP_TIME seconds..."
        log "INFO" "Waiting for status ${status}... (attempt $((retries + 1))/${max_retries}) current_status is ${current_status}..."
        sleep $sleep_time
        retries=$((retries + 1))
    done
    
    log "ERROR" "Timeout waiting for cluster ${CLUSTER_NAME} to reach status: ${status}"
    return 1
}

function start_cluster_installation() {
    log "INFO" "Starting installation for cluster ${CLUSTER_NAME}..."

    # Reuse check_cluster_installed to handle multiple clusters with same name
    if check_cluster_installed; then
        log "INFO" "Cluster ${CLUSTER_NAME} is already installed. Fetching kubeconfig..."
        get_kubeconfig
        return 0
    fi

    log "INFO" "Waiting for cluster to be ready..."
    wait_for_cluster_status "ready"
    aicli start cluster ${CLUSTER_NAME}
    log "INFO" "Waiting for cluster to be finalizing..."
    wait_for_cluster_status "finalizing"
    log "INFO" "Waiting for installation to complete..."
    wait_for_cluster_status "installed"
    log "INFO" "Cluster installation completed successfully"
    get_kubeconfig
    if [ "${USE_V419_WORKAROUND}" == "true" ]; then
        log "INFO" "Using v4.19 workaround. Deploying LSO and ODF..."
        deploy_lso
        deploy_odf
    fi
}

function get_kubeconfig() {
    log "INFO" "Getting kubeconfig..."
    
    # Determine the kubeconfig path (from environment or env.sh)
    local kubeconfig_path="${KUBECONFIG:-}"
    
    if [ -z "${kubeconfig_path}" ]; then
        log "INFO" "KUBECONFIG not set in environment, checking env.sh..."
        source "$(dirname "$0")/env.sh"
        kubeconfig_path="${KUBECONFIG:-}"
    fi

    # Trim whitespace using a more readable approach
    kubeconfig_path=$(echo "$kubeconfig_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "KUBECONFIG: $kubeconfig_path"
    if [ ! -f "$kubeconfig_path" ]; then
        log "INFO" "Downloading kubeconfig for $CLUSTER_NAME"
        aicli download kubeconfig "$CLUSTER_NAME"
        copy_error=$(cp "kubeconfig.$CLUSTER_NAME" "$kubeconfig_path" 2>&1) || true
        log "INFO" "Kubeconfig downloaded to $KUBECONFIG"
    else
        log "INFO" "Using existing kubeconfig at: $KUBECONFIG"
    fi
    # Validate the kubeconfig path
    if [ -n "${kubeconfig_path}" ] && [ -f "${kubeconfig_path}" ] && [ -r "${kubeconfig_path}" ]; then
        log "INFO" "Using KUBECONFIG: ${kubeconfig_path}"
        export KUBECONFIG="${kubeconfig_path}"
        return 0
    else
        log "ERROR" "KUBECONFIG file not found or inaccessible: ${kubeconfig_path}${copy_error:+ (Copy error: $copy_error)}"
        exit 1
    fi
}

function get_kubeadmin_password() {
    log "INFO" "Downloading kubeadmin password for cluster ${CLUSTER_NAME}..."
    
    if ! aicli download kubeadmin-password "${CLUSTER_NAME}"; then
        log "ERROR" "Failed to download kubeadmin password for cluster ${CLUSTER_NAME}"
        return 1
    fi
    
    local password_file="kubeadmin-password.${CLUSTER_NAME}"
    if [ -f "${password_file}" ]; then
        log "INFO" "Kubeadmin password downloaded to: ${password_file}"
        log "INFO" "Password: $(cat "${password_file}")"
        log "INFO" "You can use this password to connect to the OpenShift console at:"
        log "INFO" "  https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
        log "INFO" "  Username: kubeadmin"
    else
        log "WARN" "Password file not found at expected location: ${password_file}"
    fi
}

function clean_all() {
    log "Performing full cleanup of cluster and VMs..."
    
    # Delete the cluster
    delete_cluster
    
    # Delete VMs
    log "INFO" "Deleting VMs with prefix $VM_PREFIX..."
    env VM_PREFIX="$VM_PREFIX" scripts/delete_vms.sh || true
    
    # Clean resources
    clean_resources
    
    log "Full cleanup complete"
}

function deploy_lso() {
    # Only deploy LSO for multi-node clusters
    if [ "${VM_COUNT}" -le 1 ]; then
        log "INFO" "Single-node cluster detected (VM_COUNT=${VM_COUNT}). Skipping LSO deployment."
        return 0
    fi
    
    log "INFO" "Multi-node cluster detected (VM_COUNT=${VM_COUNT}). Deploying Local Storage Operator..."
    
    get_kubeconfig
    
    # Check if LSO subscription already exists
    if oc get subscription -n openshift-local-storage local-storage-operator &>/dev/null; then
        log "INFO" "LSO subscription already exists. Skipping subscription deployment."
    else
        log "INFO" "Deploying LSO subscription..."
        mkdir -p "$GENERATED_DIR"
        
        # Process subscription template
        process_template \
            "${MANIFESTS_DIR}/cluster-installation/lso/lso-subscription.yaml" \
            "${GENERATED_DIR}/lso-subscription.yaml" \
            "<CATALOG_SOURCE_NAME>" "${CATALOG_SOURCE_NAME}"
        
        apply_manifest "${GENERATED_DIR}/lso-subscription.yaml" true
    fi
    
    # Wait for LSO operator pods to be ready
    log "INFO" "Waiting for LSO operator to be ready..."
    wait_for_pods "openshift-local-storage" "name=local-storage-operator" 60 5
    

    apply_manifest "${MANIFESTS_DIR}/cluster-installation/lso/lso-volumes.yaml" false
    
    log "INFO" "LSO deployment completed successfully!"
    log "INFO" "Local storage will use block devices on nodes"
}





# Create ODF cluster as a workaround for OCS cluster creation issue
# This is a temporary solution until the OCS cluster creation with LSO 4.19 will be fixed
function deploy_odf() {
    # Only deploy ODF for multi-node clusters
    if [ "${VM_COUNT}" -le 1 ]; then
        log "INFO" "Single-node cluster detected (VM_COUNT=${VM_COUNT}). Skipping ODF deployment."
        return 0
    fi
    
    log "INFO" "Multi-node cluster detected (VM_COUNT=${VM_COUNT}). Deploying OpenShift Data Foundation..."
    
    get_kubeconfig
    
    # Check if ODF subscription already exists
    if oc get subscription -n openshift-storage odf-operator &>/dev/null; then
        log "INFO" "ODF subscription already exists. Skipping subscription deployment."
    else
        log "INFO" "Deploying ODF subscription using catalog: ${CATALOG_SOURCE_NAME}"

        # Generate ODF subscription from template
        mkdir -p "$GENERATED_DIR"
        process_template \
            "${MANIFESTS_DIR}/odf/odf-subscription.yaml" \
            "${GENERATED_DIR}/odf-subscription.yaml" \
            "<CATALOG_SOURCE_NAME>" "${CATALOG_SOURCE_NAME}"

        apply_manifest "${GENERATED_DIR}/odf-subscription.yaml" true
    fi
    
    # Wait for ODF operator to create StorageCluster CRD
    log "INFO" "Waiting for ODF StorageCluster CRD to be available..."
    local max_retries=60
    local sleep_time=10
    
    if retry 60 10 oc get storagecluster -A >/dev/null 2>&1; then
        log "INFO" "ODF StorageCluster CRD is available"
    else
        log "ERROR" "Timeout waiting for ODF StorageCluster CRD"
        return 1
    fi
    
    apply_manifest "${MANIFESTS_DIR}/odf/odf-cluster.yaml" false
    
    # Wait for StorageCluster to be ready
    log "INFO" "Waiting for ODF StorageCluster to be Ready..."
    if retry 120 10 bash -c 'oc get storagecluster -n openshift-storage ocs-storagecluster -o jsonpath="{.status.phase}" 2>/dev/null | grep -q "^Ready$"'; then
        log "INFO" "✅ ODF StorageCluster is Ready"
    else
        log "ERROR" "Timeout waiting for ODF StorageCluster to be Ready"
        log "ERROR" "Check status manually: oc get storagecluster -n openshift-storage ocs-storagecluster"
        return 1
    fi
    
    log "INFO" "ODF deployment completed successfully!"
}

# -----------------------------------------------------------------------------
# ISO management functions
# -----------------------------------------------------------------------------

function create_day2_cluster() {
    # Move cluster to day2 mode for adding worker nodes to existing cluster
    log "INFO" "Checking cluster ${CLUSTER_NAME} for day2 transition..."

    # Get cluster ID and status in a single call
    local cluster_id cluster_status
    read -r cluster_id cluster_status <<< "$(aicli -o json info cluster "${CLUSTER_NAME}" | jq -r '[.id, .status] | @tsv')"

    if [ -z "${cluster_id}" ] || [ -z "${cluster_status}" ]; then
        log "ERROR" "Cluster ${CLUSTER_NAME} not found or failed to retrieve cluster information"
        return 1
    fi

    log "INFO" "Found cluster ${CLUSTER_NAME} (ID: ${cluster_id}, Status: ${cluster_status})"

    # Check if cluster is already in adding-hosts status (day2 mode)
    if [ "${cluster_status}" = "adding-hosts" ]; then
        log "INFO" "Cluster ${CLUSTER_NAME} was already moved to day2 mode"
        return 0
    fi

    # Check if cluster is installed
    if [ "${cluster_status}" != "installed" ]; then
        log "ERROR" "Cannot move cluster ${CLUSTER_NAME} to day2 mode. Cluster must be installed first (current status: ${cluster_status})"
        return 1
    fi

    # Move cluster to day2 mode
    log "INFO" "Moving cluster ${CLUSTER_NAME} (ID: ${cluster_id}) to day2 mode..."
    if ! aicli update cluster "${cluster_id}" -P day2=true -P infraenv=false; then
        log "ERROR" "Failed to update cluster ${CLUSTER_NAME} to day2 mode"
        return 1
    fi

    log "INFO" "Cluster ${CLUSTER_NAME} successfully moved to day2 mode"
    return 0
}

function get_iso() {
    local cluster_name="${1:-${CLUSTER_NAME}}"
    local cluster_type="${2:-day2}"
    local action="${3:-download}"
    local download_path="${ISO_FOLDER}"
    local iso_type="${ISO_TYPE}"

    # Check if this is for day1 (master nodes) and cluster is already installed
    if [ "${cluster_type}" = "day1" ] && [ "${action}" = "download" ]; then
        # Use a subshell to avoid side effects from modifying CLUSTER_NAME
        if (
            CLUSTER_NAME="${cluster_name}"
            check_cluster_installed
        ); then
            log "INFO" "Skipping ISO download as cluster is already installed"
            return 0
        fi
    fi

    log "INFO" "Getting ISO URL..."
    local iso_url="$(aicli info iso "${cluster_name}" -s)"

    if [ -z "${iso_url}" ]; then
        log "INFO" "No direct URL found. Use console.redhat.com to generate an ISO."
        iso_url="https://console.redhat.com/openshift"
    fi

    iso_url="${iso_url%/*}/${iso_type}.iso"

    if [ "${action}" = "url" ]; then
        echo "${iso_url}"
        return 0
    fi

    mkdir -p "${download_path}" || true

    if ! aicli download iso "${cluster_name}" -p "${download_path}"; then
        log "ERROR" "Failed to download ISO for cluster ${cluster_name}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
function main() {
    local command=$1
    shift

    case "$command" in
        check-create-cluster)
            check_create_cluster
            ;;
        delete-cluster)
            delete_cluster
            ;;
        cluster-install)
            start_cluster_installation
            ;;
        wait-for-status)
            wait_for_cluster_status "$1"
            ;;
        get-kubeconfig)
            get_kubeconfig
            ;;
        get-kubeadmin-password)
            get_kubeadmin_password
            ;;
        clean-all)
            clean_all
            ;;
        download-iso)
            # Download ISO for master nodes
            get_iso "${CLUSTER_NAME}" "day1" "download"
            ;;
        get-day2-iso)
            # Get worker ISO URL
            get_iso "${CLUSTER_NAME}" "day2" "url"
            ;;
        create-day2-cluster)
            create_day2_cluster
            ;;
        deploy-lso)
            deploy_lso
            ;;
        deploy-odf)
            deploy_odf
            ;;
        *)
            log "Unknown command: $command"
            log "Available commands: check-create-cluster, delete-cluster, cluster-install,"
            log "  wait-for-status, get-kubeconfig, get-kubeadmin-password, clean-all, download-iso, create-day2-cluster, get-day2-iso, deploy-lso, deploy-odf"
            exit 1
            ;;
    esac
}

# If script is executed directly (not sourced), run the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        log "INFO" "Usage: $0 <command> [arguments...]"
        exit 1
    fi
    
    main "$@"
fi 
