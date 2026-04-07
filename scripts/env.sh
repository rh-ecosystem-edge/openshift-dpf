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

validate_env_files() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local ci_dir="${script_dir}/../ci"

    defaults=$(grep -oP "^\w+" "$ci_dir/env.defaults" | sort)
    template=$(grep -oP "^\w+" "$ci_dir/env.template" | sort)
    required=$(grep -oP "\w+(?=:)" "$ci_dir/env.required" | sort)
    known=$(echo "$defaults"; echo "$required")

    missing=""
    for var in $defaults; do
        if ! echo "$template" | grep -qx "$var"; then
            missing="$missing $var"
        fi
    done

    extra=""
    for var in $template; do
        if ! echo "$known" | grep -qx "$var"; then
            extra="$extra $var"
        fi
    done

    if [ -n "$missing" ]; then
        echo "ERROR: variables in ci/env.defaults that are missing from ci/env.template:"
        for var in $missing; do echo "  - $var"; done
        echo ""
        echo "These variables will be silently dropped from .env."
        echo "Fix: add a line  VAR_NAME=\${VAR_NAME}  to ci/env.template for each."
        exit 1
    fi

    if [ -n "$extra" ]; then
        count=$(echo $extra | wc -w | tr -d " ")
        echo "OK  $count template-only variable(s) have no default (set per-environment):${extra}"
    fi

    echo "OK  all ci/env.defaults variables are present in ci/env.template"
}

generate_env() {
    local force="${1:-false}"
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local root_dir="${script_dir}/.."
    local ci_dir="${root_dir}/ci"

    if [ -f "${root_dir}/.env" ] && [ "$force" != "true" ]; then
        echo "ERROR: .env already exists. To overwrite, run:  make generate-env FORCE=true"
        exit 1
    fi

    echo "Generating .env from ci/env.defaults + ci/env.template..."
    (
        set -a
        source "$ci_dir/env.defaults"
        set +a
        source "$ci_dir/env.required"
        envsubst < "$ci_dir/env.template" > "${root_dir}/.env"
    )
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

# aicli uses HOME to find ~/.aicli/offlinetoken.txt. Default: $HOME. Override with AICLI_HOME (e.g. in .env).
# When using AICLI_HOME, OPENSHIFT_PULL_SECRET must be a pull secret for the same Red Hat account as that token.
AICLI_HOME=${AICLI_HOME:-$HOME}
if [[ "$AICLI_HOME" != "$HOME" ]] && [[ ! -f "${AICLI_HOME}/.aicli/offlinetoken.txt" ]]; then
    echo "Error: ${AICLI_HOME}/.aicli/offlinetoken.txt not found." >&2
    exit 1
fi
export HOME="${AICLI_HOME}"
if ! aicli list clusters &>/dev/null; then
    echo "Error: aicli list clusters failed. Check token at ${AICLI_HOME}/.aicli/offlinetoken.txt and connectivity." >&2
    exit 1
fi

# Computed / conditional variables — derived from .env values at runtime.
# Only evaluate when sourced by other scripts (not when executed directly for
# standalone commands like validate-env-files / generate-env).
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    HELM_CHARTS_DIR=${HELM_CHARTS_DIR:-"$MANIFESTS_DIR/helm-charts-values"}
    HOST_CLUSTER_API=${HOST_CLUSTER_API:-"api.$CLUSTER_NAME.$BASE_DOMAIN"}
    HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CONTROL_PLANE_NAMESPACE:-"${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"}

    # OLM Catalog Source — when OLM_WORKAROUND=true, use the previous OCP
    # minor version's catalog (e.g. 4.20→4.19, 4.22→4.21).
    CATALOG_SOURCE_NAME=${CATALOG_SOURCE_NAME:-"redhat-operators"}
    if [[ "${OLM_WORKAROUND}" == "true" ]]; then
        _ocp_minor="${OPENSHIFT_VERSION#*.}"
        _ocp_minor="${_ocp_minor%%.*}"
        OLM_WORKAROUND_VERSION="${OPENSHIFT_VERSION%%.*}.$(( _ocp_minor - 1 ))"
        CATALOG_SOURCE_NAME="redhat-operators-v${OLM_WORKAROUND_VERSION}"
        unset _ocp_minor
    fi

    # Auto-resolve OVN-Kubernetes image from the aarch64 OCP release payload
    # Skip if the user already set OVN_KUBERNETES_IMAGE_TAG in .env
    if [ -z "${OVN_KUBERNETES_IMAGE_TAG:-}" ] && command -v oc &>/dev/null; then
        _ovnk_full=$(oc adm release info --image-for=ovn-kubernetes \
            "quay.io/openshift-release-dev/ocp-release:${OPENSHIFT_VERSION}-aarch64" 2>/dev/null || true)
        if [ -n "$_ovnk_full" ]; then
            OVN_KUBERNETES_IMAGE_REPO="${_ovnk_full%@*}@sha256"
            OVN_KUBERNETES_IMAGE_TAG="${_ovnk_full##*sha256:}"
        fi
    fi

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
fi

# If script is executed directly (not sourced), handle commands
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    command=$1
    case $command in
        validate-env-files)
            validate_env_files
            ;;
        generate-env)
            generate_env "${2:-false}"
            ;;
        *)
            echo "ERROR: Unknown command: $command"
            echo "Available commands: validate-env-files, generate-env"
            exit 1
            ;;
    esac
fi
