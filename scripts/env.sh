#!/bin/bash

# Exit on error
set -e

# Prevent double sourcing
if [ -n "${ENV_SH_SOURCED:-}" ]; then
    return 0
fi
export ENV_SH_SOURCED=1

# Function to load environment variables from .env file
load_env() {
    # Find the .env file relative to the script location
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local env_file="${script_dir}/../.env"
    
    # Check if .env file exists
    if [ ! -f "$env_file" ]; then
        # If running from Makefile, .env is already loaded
        if [ -n "${MAKEFILE:-}" ] || [ -n "${MAKELEVEL:-}" ]; then
            return 0
        fi
        echo "Error: .env file not found at $env_file"
        exit 1
    fi

    # Load environment variables from .env file
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^#.*$ ]] && continue
        [[ -z $key ]] && continue
        # Remove any quotes from the value
        value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        
        # Export the variable
        export "$key=$value"
    done < "$env_file"
}

validate_mtu() {
    if [ "$NODES_MTU" != "1500" ] && [ "$NODES_MTU" != "9000" ]; then
        echo "Error: NODES_MTU must be either 1500 or 9000. Current value: $NODES_MTU"
        exit 1
    fi
}

# Load environment variables from .env file (skip if already in Make context)
if [ -z "${MAKELEVEL:-}" ]; then
    load_env
    validate_mtu
fi

# Computed / conditional variables — derived from .env values at runtime.
HELM_CHARTS_DIR=${HELM_CHARTS_DIR:-"$MANIFESTS_DIR/helm-charts-values"}
HOST_CLUSTER_API=${HOST_CLUSTER_API:-"api.$CLUSTER_NAME.$BASE_DOMAIN"}
HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CONTROL_PLANE_NAMESPACE:-"${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"}

# Storage class — conditional on STORAGE_TYPE and SKIP_DEPLOY_STORAGE
if [ "${STORAGE_TYPE}" == "odf" ] && [ "${VM_COUNT}" -lt 3 ]; then
    echo "Warning: ODF requires at least 3 nodes. Falling back to LVM." >&2
    STORAGE_TYPE="lvm"
fi

if [ "${SKIP_DEPLOY_STORAGE}" = "true" ]; then
    if [ -z "${ETCD_STORAGE_CLASS}" ]; then
        echo "Error: SKIP_DEPLOY_STORAGE=true requires ETCD_STORAGE_CLASS to be set in .env to your existing StorageClass name." >&2
        echo "Create the StorageClass in the cluster (e.g. via your storage operator), then set ETCD_STORAGE_CLASS in .env." >&2
        exit 1
    fi
elif [ "${STORAGE_TYPE}" == "odf" ]; then
    ETCD_STORAGE_CLASS=${ETCD_STORAGE_CLASS:-"ocs-storagecluster-ceph-rbd"}
else
    ETCD_STORAGE_CLASS=${ETCD_STORAGE_CLASS:-"lvms-vg1"}
fi
