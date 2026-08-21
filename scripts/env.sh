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

# _do_validate_env_files <defaults_file> <template_file> <required_file> <output_file>
_do_validate_env_files() {
    local defaults_file="$1" template_file="$2" required_file="$3" output_file="$4"

    local defaults template required known missing extra count
    defaults=$(grep -oP "^\w+" "$defaults_file" | sort)
    template=$(grep -oP "^\w+" "$template_file" | sort)
    required=$(grep -v '^\s*#' "$required_file" | grep -oP '(?<=\$\{)\w+(?=:\?)' | sort)
    known=$(printf '%s\n%s' "$defaults" "$required")

    missing=""
    for var in $defaults $required; do
        echo "$template" | grep -qx "$var" || missing="$missing $var"
    done

    extra=""
    for var in $template; do
        echo "$known" | grep -qx "$var" || extra="$extra $var"
    done

    if [ -n "$missing" ]; then
        echo "ERROR: variables in $(basename "$defaults_file") that are missing from $(basename "$template_file"):"
        for var in $missing; do echo "  - $var"; done
        echo ""
        echo "These variables will be silently dropped from $output_file."
        echo "Fix: add a line  VAR_NAME=\${VAR_NAME}  to $(basename "$template_file") for each."
        exit 1
    fi

    if [ -n "$extra" ]; then
        count=$(echo "$extra" | wc -w | tr -d " ")
        echo "OK  $count template-only variable(s) have no default (set per-environment):${extra}"
    fi

    echo "OK  all $(basename "$defaults_file") variables are present in $(basename "$template_file")"
}

validate_env_files() {
    local script_dir ci_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ci_dir="${script_dir}/../ci"
    _do_validate_env_files "$ci_dir/env.defaults" "$ci_dir/env.template" "$ci_dir/env.required" ".env"
}

validate_env_test_files() {
    local script_dir ci_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ci_dir="${script_dir}/../ci"
    _do_validate_env_files "$ci_dir/env.test.defaults" "$ci_dir/env.test.template" "$ci_dir/env.test.required" ".env.test"
}

# _do_generate_env <defaults_file> <required_file> <template_file> <output_file> <force>
_do_generate_env() {
    local defaults_file="$1" required_file="$2" template_file="$3"
    local output_file="$4" force="${5:-false}"

    if [ -f "$output_file" ] && [ "$force" != "true" ]; then
        echo "ERROR: $output_file already exists. To overwrite, run with FORCE=true"
        exit 1
    fi

    echo "Generating $output_file..."
    (
        set -a
        source "$defaults_file"
        set +a
        source "$required_file"
        envsubst < "$template_file" > "$output_file"
    )
}

generate_env() {
    local script_dir root_dir ci_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    root_dir="${script_dir}/.."
    ci_dir="${root_dir}/ci"
    _do_generate_env \
        "$ci_dir/env.defaults" "$ci_dir/env.required" "$ci_dir/env.template" \
        "${root_dir}/.env" "${1:-false}"
}

generate_env_test() {
    local script_dir root_dir ci_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    root_dir="${script_dir}/.."
    ci_dir="${root_dir}/ci"
    _do_generate_env \
        "$ci_dir/env.test.defaults" "$ci_dir/env.test.required" "$ci_dir/env.test.template" \
        "${root_dir}/.env.test" "${1:-false}"
}

validate_mtu() {
    if [ "$NODES_MTU" != "1500" ] && [ "$NODES_MTU" != "9000" ]; then
        echo "Error: NODES_MTU must be either 1500 or 9000. Current value: $NODES_MTU"
        exit 1
    fi
}

# Load environment variables from .env file and validate aicli connectivity
# (skip if already in Make context — the Makefile does `include .env` + `export`)
if [ -z "${MAKELEVEL:-}" ]; then
    load_env
    validate_mtu

    if [ -z "${PAYLOAD_URL:-}" ]; then
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
    fi
fi

# Computed / conditional variables — derived from .env values at runtime.
# Only evaluate when sourced by other scripts (not when executed directly for
# standalone commands like validate-env-files / generate-env).
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    HELM_CHARTS_DIR=${HELM_CHARTS_DIR:-"$MANIFESTS_DIR/helm-charts-values"}
    HOST_CLUSTER_API=${HOST_CLUSTER_API:-"api.$CLUSTER_NAME.$BASE_DOMAIN"}
    HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CONTROL_PLANE_NAMESPACE:-"${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"}

    # When PAYLOAD_URL is set (e.g. by Prow), derive OPENSHIFT_VERSION and
    # OCP_RELEASE_IMAGE from the release payload instead of using .env defaults.
    if [ -n "${PAYLOAD_URL:-}" ]; then
        export AI_URL="http://127.0.0.1:8090"
        if ! command -v oc &>/dev/null; then
            echo "Error: PAYLOAD_URL is set but 'oc' is not available" >&2
            exit 1
        fi
        if ! _release_info=$(oc adm release info "$PAYLOAD_URL" 2>&1); then
            echo "Error: 'oc adm release info' failed for ${PAYLOAD_URL}:" >&2
            echo "$_release_info" >&2
            exit 1
        fi
        _payload_version=$(echo "$_release_info" | awk '/^Name:/{print $2}')
        if [ -z "$_payload_version" ]; then
            echo "Error: could not parse version from release info for ${PAYLOAD_URL}" >&2
            exit 1
        fi
        OPENSHIFT_VERSION="$_payload_version"
        _multi_image="quay.io/openshift-release-dev/ocp-release:${_payload_version}-multi"
        if ! oc adm release info "$_multi_image" &>/dev/null; then
            echo "Error: multi-arch release image not found: ${_multi_image}" >&2
            exit 1
        fi
        OCP_RELEASE_IMAGE="$_multi_image"
        echo "PAYLOAD_URL set: OPENSHIFT_VERSION=${OPENSHIFT_VERSION}, OCP_RELEASE_IMAGE=${OCP_RELEASE_IMAGE}"
        unset _multi_image
        unset _payload_version _release_info
    fi

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

    # Auto-resolve OVN-Kubernetes image from the aarch64 OCP release payload.
    # The DPU is always aarch64 regardless of the host architecture.
    # Strip -multi suffix from the version since per-arch tags use e.g. 4.22.7-aarch64.
    if [ -z "${OVN_KUBERNETES_IMAGE_TAG:-}" ] && command -v oc &>/dev/null; then
        _ocp_base_version="${OPENSHIFT_VERSION%-multi}"
        _ovnk_full=$(oc adm release info --image-for=ovn-kubernetes \
            "quay.io/openshift-release-dev/ocp-release:${_ocp_base_version}-aarch64" 2>/dev/null || true)
        if [ -n "$_ovnk_full" ]; then
            OVN_KUBERNETES_IMAGE_REPO="${_ovnk_full%@*}@sha256"
            OVN_KUBERNETES_IMAGE_TAG="${_ovnk_full##*sha256:}"
        fi
        unset _ocp_base_version
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
        validate-env-test-files)
            validate_env_test_files
            ;;
        generate-env-test)
            generate_env_test "${2:-false}"
            ;;
        *)
            echo "ERROR: Unknown command: $command"
            echo "Available commands: validate-env-files, generate-env, validate-env-test-files, generate-env-test"
            exit 1
            ;;
    esac
fi
