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
        # The output holds BMC passwords.
        umask 077
        set -a
        source "$defaults_file"
        set +a
        source "$required_file"
        if [ "$(basename "${required_file}")" = "env.required" ] &&
           [ "${DPF_DEPLOYMENT_MODE:-}" = "zero-trust" ]; then
            source "$(dirname "${BASH_SOURCE[0]}")/validate-env.sh"
            validate_zero_trust_mode
        fi
        envsubst < "$template_file" > "$output_file"
        chmod 600 "$output_file"

        if [ "${DPF_DEPLOYMENT_MODE:-}" = "zero-trust" ]; then
            # Workers 1 and 2 are rendered by env.template; append higher-numbered hosts.
            local host variable
            while IFS= read -r host; do
                for variable in \
                    "WORKER_${host}_DPU_BMC_IPS" \
                    "WORKER_${host}_BMC_IP" \
                    "WORKER_${host}_BMC_USER" \
                    "WORKER_${host}_BMC_PASSWORD"; do
                    if ! grep -q "^${variable}=" "$output_file"; then
                        printf '%s=%s\n' "${variable}" "${!variable:-}" >> "$output_file"
                    fi
                done
            done < <(list_zero_trust_dpu_hosts)
        fi
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

is_dpf_profile() {
    [ "${DEPLOYMENT_PROFILE:-dpf}" = "dpf" ]
}

is_nno_profile() {
    [ "${DEPLOYMENT_PROFILE:-dpf}" = "nno" ]
}

# DPF workers are DPU hosts unless WORKER_n_DPU=false.
# NNO workers are regular nodes unless WORKER_n_DPU=true.
default_worker_is_dpu() {
    if is_nno_profile; then
        printf '%s' false
    else
        printf '%s' true
    fi
}

# ODF fallback and ETCD class defaults are DPF-only. NNO has no hosted-cluster
# etcd. Validation of user-provided storage settings happens in validate-env.sh.
resolve_dpf_storage_class() {
    is_dpf_profile || return 0

    if [ "${STORAGE_TYPE}" == "odf" ] && [ "${VM_COUNT}" -lt 3 ]; then
        echo "Warning: ODF requires at least 3 nodes. Falling back to LVM." >&2
        STORAGE_TYPE="lvm"
    fi

    if [ "${SKIP_DEPLOY_STORAGE}" != "true" ] && [ "${STORAGE_TYPE}" == "odf" ]; then
        ETCD_STORAGE_CLASS=${ETCD_STORAGE_CLASS:-"ocs-storagecluster-ceph-rbd"}
    elif [ "${SKIP_DEPLOY_STORAGE}" != "true" ]; then
        ETCD_STORAGE_CLASS=${ETCD_STORAGE_CLASS:-"lvms-vg1"}
    fi
}

# Print the indexes of the hosts whose WORKER_<N>_DPU_BMC_IPS lists at least one
# DPU, in numeric order. Additional numbered variables can be supplied through
# .env, the process environment, or the make command line.
list_zero_trust_dpu_hosts() {
    local variable index
    while IFS= read -r variable; do
        [ -n "${!variable//[[:space:],]/}" ] || continue
        index="${variable#WORKER_}"
        echo "${index%_DPU_BMC_IPS}"
    done < <(compgen -A variable | grep -E '^WORKER_[1-9][0-9]*_DPU_BMC_IPS$' | sort -V || true)
}

# Print the DPU BMC IPs listed for host <N>, one per line, in the listed order.
list_zero_trust_host_dpu_bmc_ips() {
    local variable="WORKER_$1_DPU_BMC_IPS"
    local ip
    local -a ips=()

    IFS=',' read -r -a ips <<< "${!variable:-}"
    for ip in "${ips[@]}"; do
        ip="${ip//[[:space:]]/}"
        if [ -n "${ip}" ]; then
            echo "${ip}"
        fi
    done
}

zero_trust_dpu_node_name() {
    echo "dpu-node-worker-$1"
}

# When PAYLOAD_URL is set (e.g. by Prow), derive OPENSHIFT_VERSION from it.
resolve_payload() {
    export AI_URL="${AI_URL:-http://127.0.0.1:8090}"
    if ! command -v oc &>/dev/null; then
        echo "Error: PAYLOAD_URL is set but 'oc' is not available" >&2
        exit 1
    fi
    local -a _oc_registry_flags=()
    if [ -f "${OPENSHIFT_PULL_SECRET:-}" ]; then
        _oc_registry_flags=(--registry-config="${OPENSHIFT_PULL_SECRET}")
    fi
    local _release_info
    if ! _release_info=$(oc adm release info "${_oc_registry_flags[@]}" "$PAYLOAD_URL" 2>&1); then
        echo "Error: 'oc adm release info' failed for ${PAYLOAD_URL}:" >&2
        echo "$_release_info" >&2
        exit 1
    fi
    local _payload_version
    _payload_version=$(echo "$_release_info" | awk '/^Name:/{print $2}')
    if [ -z "$_payload_version" ]; then
        echo "Error: could not parse version from release info for ${PAYLOAD_URL}" >&2
        exit 1
    fi
    export OPENSHIFT_VERSION="$_payload_version"
    # Restore this selection when NVIDIA-1612 can choose an available BlueField OCP layer:
    # local _multi_image="quay.io/openshift-release-dev/ocp-release:${_payload_version}-multi"
    # if oc adm release info "${_oc_registry_flags[@]}" "$_multi_image" &>/dev/null; then
    #     export OCP_RELEASE_IMAGE="$_multi_image"
    # else
    #     export OCP_RELEASE_IMAGE="$PAYLOAD_URL"
    # fi
    # WA: pin hosted OCP until CI selects the latest matching BlueField layer (NVIDIA-1612).
    export OCP_RELEASE_IMAGE="${OCP_RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:4.22.19-multi}"
    echo "PAYLOAD_URL set: OPENSHIFT_VERSION=${OPENSHIFT_VERSION}, OCP_RELEASE_IMAGE=${OCP_RELEASE_IMAGE}"
}

# Load and derive configuration only when sourced by other scripts. Validation
# runs separately through scripts/validate-env.sh, once at workflow startup.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    if [ -z "${MAKELEVEL:-}" ]; then
        load_env
    else
        # Make includes .env and exports it. Strip quotes Make left on values
        # without re-reading the file, which would clobber make VAR=value overrides.
        _strip_exported_env_quotes
    fi

    # aicli reads its token from HOME; preserve AICLI_HOME as a runtime override.
    ENV_SH_ORIGINAL_HOME=${ENV_SH_ORIGINAL_HOME:-$HOME}
    export ENV_SH_ORIGINAL_HOME
    AICLI_HOME=${AICLI_HOME:-$HOME}
    export HOME="${AICLI_HOME}"

    # Compatibility default for .env files generated before deployment profiles
    # were introduced.
    DPF_DEPLOYMENT_MODE=${DPF_DEPLOYMENT_MODE:-host-trusted}

    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        if [ "${VM_COUNT}" -eq 1 ]; then
            HYPERSHIFT_API_IP=""
            export HYPERSHIFT_API_IP
        fi
    fi

    MANIFESTS_DIR=${MANIFESTS_DIR:-manifests}
    POST_INSTALL_DIR="${MANIFESTS_DIR}/post-installation"
    COMMON_POST_INSTALL_DIR="${POST_INSTALL_DIR}/common"
    HOST_TRUSTED_POST_INSTALL_DIR="${POST_INSTALL_DIR}/host-trusted"
    ZERO_TRUST_POST_INSTALL_DIR="${POST_INSTALL_DIR}/zero-trust"

    HELM_CHARTS_DIR=${HELM_CHARTS_DIR:-"$MANIFESTS_DIR/helm-charts-values"}
    HOST_CLUSTER_API=${HOST_CLUSTER_API:-"api.$CLUSTER_NAME.$BASE_DOMAIN"}
    HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CONTROL_PLANE_NAMESPACE:-"${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"}
    HOSTED_KUBECONFIG="${HOSTED_CLUSTER_NAME}.kubeconfig"

    if [ -n "${PAYLOAD_URL:-}" ] && [ -z "${ENV_SH_VALIDATION_ONLY:-}" ]; then
        resolve_payload
    fi

    # OLM Catalog Source — when OLM_WORKAROUND=true, use the previous OCP
    # minor version's catalog (e.g. 4.20→4.19, 4.22→4.21).
    CATALOG_SOURCE_NAME=${CATALOG_SOURCE_NAME:-"redhat-operators"}
    if [ -z "${ENV_SH_VALIDATION_ONLY:-}" ] && [[ "${OLM_WORKAROUND}" == "true" ]]; then
        _ocp_minor="${OPENSHIFT_VERSION#*.}"
        _ocp_minor="${_ocp_minor%%.*}"
        OLM_WORKAROUND_VERSION="${OPENSHIFT_VERSION%%.*}.$(( _ocp_minor - 1 ))"
        CATALOG_SOURCE_NAME="redhat-operators-v${OLM_WORKAROUND_VERSION}"
        unset _ocp_minor
    fi

    # Auto-resolve OVN-Kubernetes image from the aarch64 OCP release payload.
    # The DPU is always aarch64 regardless of the host architecture.
    # Strip -multi suffix from the version since per-arch tags use e.g. 4.22.7-aarch64.
    if [ -z "${ENV_SH_VALIDATION_ONLY:-}" ] && is_dpf_profile &&
        [ -z "${OVN_KUBERNETES_IMAGE_TAG:-}" ] && command -v oc &>/dev/null; then
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
    KATA_SRIOV_DP_CONFIG_NAME=${KATA_SRIOV_DP_CONFIG_NAME:-bf3-p0-vfs-kata}
    KATA_NUM_VFS=${KATA_NUM_VFS:-24}
    KATA_NAD_NAME=${KATA_NAD_NAME:-dpf-ovn-kubernetes-${KATA_RUNTIME_CLASS}}
    KATA_INJECTOR_RESOURCE_NAME=${KATA_INJECTOR_RESOURCE_NAME:-${SRIOV_DP_RESOURCE_PREFIX}/${KATA_SRIOV_DP_CONFIG_NAME}}
    KATA_TEST_REPLICAS=${KATA_TEST_REPLICAS:-1}
    KATA_SKIP_RHCOS_LAYER=${KATA_SKIP_RHCOS_LAYER:-false}
    ARGUS_ENABLED=${ARGUS_ENABLED:-false}
    ARGUS_CHART_VERSION=${ARGUS_CHART_VERSION:-1.5.0}
    ARGUS_HELM_REPO_URL=${ARGUS_HELM_REPO_URL:-${DPF_HELM_REPO_URL}}
    ARGUS_IMAGE=${ARGUS_IMAGE:-nvcr.io/nvidia/doca/doca_argus:1.5.0-doca3.5.0}
    ARGUS_IMAGE_PULL_SECRET=${ARGUS_IMAGE_PULL_SECRET:-dpf-pull-secret}
    ARGUS_TELEMETRY_NODE_PORT=${ARGUS_TELEMETRY_NODE_PORT:-30224}

    resolve_dpf_storage_class
fi

# If script is executed directly (not sourced), handle commands
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    command=$1
    case $command in
        validate-env-files)
            exec "$(dirname "${BASH_SOURCE[0]}")/validate-env.sh" validate-env-files
            ;;
        generate-env)
            generate_env "${2:-false}"
            ;;
        validate-env-test-files)
            exec "$(dirname "${BASH_SOURCE[0]}")/validate-env.sh" validate-env-test-files
            ;;
        generate-env-test)
            generate_env_test "${2:-false}"
            ;;
        validate-zt-inventory)
            exec "$(dirname "${BASH_SOURCE[0]}")/validate-env.sh" validate-zt-inventory
            ;;
        validate-zt-mode)
            exec "$(dirname "${BASH_SOURCE[0]}")/validate-env.sh" validate-zt-mode
            ;;
        validate-host-trusted-mode)
            exec "$(dirname "${BASH_SOURCE[0]}")/validate-env.sh" validate-host-trusted-mode
            ;;
        *)
            echo "ERROR: Unknown command: $command"
            echo "Available commands: validate-env-files, generate-env, validate-env-test-files, generate-env-test, validate-zt-inventory, validate-zt-mode, validate-host-trusted-mode"
            exit 1
            ;;
    esac
fi
