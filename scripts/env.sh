#!/bin/bash

# Exit on error
set -e

# Prevent double sourcing
if [ -n "${ENV_SH_SOURCED:-}" ]; then
    return 0
fi
export ENV_SH_SOURCED=1

# GNU Make's `include .env` leaves surrounding quotes in the value, so
# KATA_ENABLED="true" is exported as "true" and boolean checks fail.
_strip_surrounding_quotes() {
    local value="$1"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s' "$value"
}

# Strip quotes from currently exported .env keys without re-reading file
# values, so `make VAR=value` overrides are preserved.
_strip_exported_env_quotes() {
    local script_dir env_file key value stripped
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    env_file="${script_dir}/../.env"
    [ -f "$env_file" ] || return 0

    while IFS='=' read -r key _; do
        [[ $key =~ ^#.*$ ]] && continue
        [[ -z $key ]] && continue
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [ -n "${!key+x}" ] || continue
        value="${!key}"
        stripped="$(_strip_surrounding_quotes "$value")"
        if [ "$stripped" != "$value" ]; then
            export "$key=$stripped"
        fi
    done < "$env_file"
}

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
        value="$(_strip_surrounding_quotes "$value")"
        
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

validate_deployment_profile() {
    case "${DEPLOYMENT_PROFILE:-dpf}" in
        dpf|nno)
            ;;
        *)
            echo "Error: DEPLOYMENT_PROFILE must be either 'dpf' or 'nno'. Current value: ${DEPLOYMENT_PROFILE}" >&2
            exit 1
            ;;
    esac
}

# Load environment variables from .env file and validate aicli connectivity
# (skip load/validate if already in Make context — the Makefile does
# `include .env` + `export`). Still strip quotes Make left on values;
# do not re-read .env or `make VAR=value` overrides would be clobbered.
if [ -z "${MAKELEVEL:-}" ]; then
    load_env
    validate_mtu

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
else
    _strip_exported_env_quotes
fi

validate_deployment_profile

# Computed / conditional variables — derived from .env values at runtime.
# Only evaluate when sourced by other scripts (not when executed directly for
# standalone commands like validate-env-files / generate-env).
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    HELM_CHARTS_DIR=${HELM_CHARTS_DIR:-"$MANIFESTS_DIR/helm-charts-values"}
    HOST_CLUSTER_API=${HOST_CLUSTER_API:-"api.$CLUSTER_NAME.$BASE_DOMAIN"}

    if [ "${DEPLOYMENT_PROFILE:-dpf}" = "dpf" ]; then
        HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CONTROL_PLANE_NAMESPACE:-"${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"}
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
    if [ "${DEPLOYMENT_PROFILE:-dpf}" = "dpf" ] && [ -z "${OVN_KUBERNETES_IMAGE_TAG:-}" ] && command -v oc &>/dev/null; then
        _ocp_base_version="${OPENSHIFT_VERSION%-multi}"
        _ovnk_full=$(oc adm release info --image-for=ovn-kubernetes \
            "quay.io/openshift-release-dev/ocp-release:${_ocp_base_version}-aarch64" 2>/dev/null || true)
        if [ -n "$_ovnk_full" ]; then
            OVN_KUBERNETES_IMAGE_REPO="${_ovnk_full%@*}@sha256"
            OVN_KUBERNETES_IMAGE_TAG="${_ovnk_full##*sha256:}"
        fi
        unset _ocp_base_version
    fi

    # Kata defaults for .env files generated before these variables existed.
    KATA_ENABLED=${KATA_ENABLED:-false}
    KATA_RUNTIME_CLASS=${KATA_RUNTIME_CLASS:-kata-coldplug}
    KATA_SRIOV_DP_CONFIG_NAME=${KATA_SRIOV_DP_CONFIG_NAME:-bf3-p1-vfs-kata}
    KATA_SRIOV_PF_INDEX=${KATA_SRIOV_PF_INDEX:-1}
    KATA_NUM_VFS=${KATA_NUM_VFS:-24}
    KATA_NAD_NAME=${KATA_NAD_NAME:-dpf-ovn-kubernetes-${KATA_RUNTIME_CLASS}}
    KATA_INJECTOR_RESOURCE_NAME=${KATA_INJECTOR_RESOURCE_NAME:-${SRIOV_DP_RESOURCE_PREFIX}/${KATA_SRIOV_DP_CONFIG_NAME}}
    KATA_TEST_REPLICAS=${KATA_TEST_REPLICAS:-1}
    KATA_SKIP_RHCOS_LAYER=${KATA_SKIP_RHCOS_LAYER:-false}

    # Storage class — conditional on STORAGE_TYPE and SKIP_DEPLOY_STORAGE
    if [ "${DEPLOYMENT_PROFILE:-dpf}" = "dpf" ] && [ "${STORAGE_TYPE}" == "odf" ] && [ "${VM_COUNT}" -lt 3 ]; then
        echo "Warning: ODF requires at least 3 nodes. Falling back to LVM." >&2
        STORAGE_TYPE="lvm"
    fi

    if [ "${DEPLOYMENT_PROFILE:-dpf}" != "dpf" ]; then
        :
    elif [ "${SKIP_DEPLOY_STORAGE}" = "true" ]; then
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
