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

require_argus_enabled() {
    if [ "${ARGUS_ENABLED:-false}" != "true" ]; then
        echo "Error: ARGUS_ENABLED must be true to run make enable-argus. Set it and regenerate .env." >&2
        return 1
    fi
}

# Argus streams alerts to a Fluent Bit NodePort on the management cluster.
# Checked at load time so a bad value fails before deployment starts.
validate_argus_config() {
    if ! is_dpf_profile; then
        echo "Error: ARGUS_ENABLED=true requires DEPLOYMENT_PROFILE=dpf (got '${DEPLOYMENT_PROFILE}')" >&2
        return 1
    fi
    if ! [[ "${ARGUS_TELEMETRY_NODE_PORT}" =~ ^[0-9]+$ ]] ||
        [ "${ARGUS_TELEMETRY_NODE_PORT}" -lt 30000 ] ||
        [ "${ARGUS_TELEMETRY_NODE_PORT}" -gt 32767 ]; then
        echo "Error: ARGUS_TELEMETRY_NODE_PORT must be in the NodePort range 30000-32767 (got '${ARGUS_TELEMETRY_NODE_PORT}')" >&2
        return 1
    fi
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
# etcd. Do not set SKIP_DEPLOY_STORAGE for NNO; that flag means DPF with a
# user-provided StorageClass and requires ETCD_STORAGE_CLASS.
resolve_dpf_storage_class() {
    is_dpf_profile || return 0

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

validate_zero_trust_dpu_inventory() {
    local invalid=0
    local variable host ip ip_value start_value end_value dpu_variable
    local -a hosts=()
    local -A seen_bmc_ips=()

    if [ -n "${ZT_DPU_DISCOVERY_MODE:-}" ]; then
        echo "ERROR: ZT_DPU_DISCOVERY_MODE is no longer supported; DPUDiscovery always scans ZT_DPU_BMC_IP_RANGE_START-ZT_DPU_BMC_IP_RANGE_END" >&2
        invalid=1
    fi
    while IFS= read -r variable; do
        [ -n "${!variable:-}" ] || continue
        echo "ERROR: ${variable} is no longer supported; list each host's DPU BMC IPs in WORKER_<N>_DPU_BMC_IPS" >&2
        invalid=1
    done < <(compgen -A variable | grep -E '^DPU[1-9][0-9]*_(SERIAL|BMC_IP)$' | sort -V || true)

    if [ -z "${ZT_DPU_BMC_IP_RANGE_START:-}" ] ||
       [ -z "${ZT_DPU_BMC_IP_RANGE_END:-}" ]; then
        echo "ERROR: Zero Trust installation requires ZT_DPU_BMC_IP_RANGE_START and ZT_DPU_BMC_IP_RANGE_END" >&2
        return 1
    fi
    if ! start_value=$(_ipv4_to_integer "${ZT_DPU_BMC_IP_RANGE_START}") ||
       ! end_value=$(_ipv4_to_integer "${ZT_DPU_BMC_IP_RANGE_END}") ||
       [ "${start_value}" -gt "${end_value}" ]; then
        echo "ERROR: Invalid Zero Trust DPU BMC IP range: ${ZT_DPU_BMC_IP_RANGE_START}-${ZT_DPU_BMC_IP_RANGE_END}" >&2
        return 1
    fi

    mapfile -t hosts < <(list_zero_trust_dpu_hosts)
    if [ "${#hosts[@]}" -eq 0 ]; then
        echo "ERROR: Zero Trust installation requires WORKER_<N>_DPU_BMC_IPS for at least one host, for example WORKER_1_DPU_BMC_IPS=10.6.136.33" >&2
        return 1
    fi

    for host in "${hosts[@]}"; do
        if [ "${host}" -gt "${WORKER_COUNT}" ]; then
            echo "ERROR: WORKER_${host}_DPU_BMC_IPS requires WORKER_${host}, but WORKER_COUNT=${WORKER_COUNT}" >&2
            invalid=1
            continue
        fi
        if [ "${host}" -gt 5 ]; then
            echo "ERROR: WORKER_${host}_DPU_BMC_IPS: the Zero Trust HBN values (VLANs 10+N and 20+N, BGP AS 65001+N*100) support hosts 1-5" >&2
            invalid=1
            continue
        fi

        dpu_variable="WORKER_${host}_DPU"
        if [ "${!dpu_variable:-$(default_worker_is_dpu)}" != "true" ]; then
            echo "ERROR: WORKER_${host}_DPU_BMC_IPS requires ${dpu_variable}=true" >&2
            invalid=1
        fi

        for variable in \
            "WORKER_${host}_BMC_IP" \
            "WORKER_${host}_BMC_USER" \
            "WORKER_${host}_BMC_PASSWORD"; do
            if [ -z "${!variable:-}" ]; then
                echo "ERROR: WORKER_${host}_DPU_BMC_IPS requires ${variable} for host reboot handling" >&2
                invalid=1
            fi
        done
        variable="WORKER_${host}_BMC_IP"
        if [ -n "${!variable:-}" ] && ! _ipv4_to_integer "${!variable}" >/dev/null; then
            echo "ERROR: ${variable} must be a valid IPv4 address" >&2
            invalid=1
        fi

        while IFS= read -r ip; do
            if ! ip_value=$(_ipv4_to_integer "${ip}"); then
                echo "ERROR: WORKER_${host}_DPU_BMC_IPS contains an invalid IPv4 address: ${ip}" >&2
                invalid=1
            elif [ "${ip_value}" -lt "${start_value}" ] || [ "${ip_value}" -gt "${end_value}" ]; then
                echo "ERROR: WORKER_${host}_DPU_BMC_IPS address ${ip} is outside ZT_DPU_BMC_IP_RANGE_START-ZT_DPU_BMC_IP_RANGE_END (${ZT_DPU_BMC_IP_RANGE_START}-${ZT_DPU_BMC_IP_RANGE_END})" >&2
                invalid=1
            elif [ -n "${seen_bmc_ips[${ip}]+x}" ]; then
                echo "ERROR: DPU BMC IP ${ip} is listed for both WORKER_${seen_bmc_ips[${ip}]} and WORKER_${host}" >&2
                invalid=1
            else
                seen_bmc_ips["${ip}"]="${host}"
            fi
        done < <(list_zero_trust_host_dpu_bmc_ips "${host}")
    done

    [ "${invalid}" -eq 0 ]
}

_ipv4_to_integer() {
    local ip="$1"
    local first second third fourth extra
    IFS=. read -r first second third fourth extra <<< "${ip}"

    if [ -n "${extra}" ] ||
       ! [[ "${first}" =~ ^[0-9]+$ && "${second}" =~ ^[0-9]+$ &&
            "${third}" =~ ^[0-9]+$ && "${fourth}" =~ ^[0-9]+$ ]] ||
       [ "$((10#${first}))" -gt 255 ] || [ "$((10#${second}))" -gt 255 ] ||
       [ "$((10#${third}))" -gt 255 ] || [ "$((10#${fourth}))" -gt 255 ]; then
        return 1
    fi

    printf '%u\n' "$(( (10#${first} * 16777216) + (10#${second} * 65536) + (10#${third} * 256) + 10#${fourth} ))"
}

validate_worker_power_on_delay() {
    if ! [[ "${WORKER_POWER_ON_DELAY}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: WORKER_POWER_ON_DELAY must be a non-negative integer" >&2
        return 1
    fi
}

validate_zero_trust_redfish_configuration() {
    [ "${DPF_DEPLOYMENT_MODE:-host-trusted}" = "zero-trust" ] || return 0

    if [ -z "${ZT_DPU_BMC_ROOT_PASSWORD:-}" ]; then
        echo "ERROR: Zero Trust installation requires ZT_DPU_BMC_ROOT_PASSWORD" >&2
        return 1
    fi

    validate_worker_power_on_delay || return 1
    validate_zero_trust_dpu_inventory || return 1
}

validate_zero_trust_mode() {
    local variable

    if [ "${DPF_DEPLOYMENT_MODE:-}" != "zero-trust" ]; then
        echo "ERROR: Zero Trust validation requires DPF_DEPLOYMENT_MODE=zero-trust" >&2
        return 1
    fi
    if [ "${HYPERSHIFT_INSTALL_METHOD:-}" != "binary" ]; then
        echo "ERROR: Zero Trust installation requires HYPERSHIFT_INSTALL_METHOD=binary" >&2
        return 1
    fi
    validate_zero_trust_redfish_configuration || return 1

    for variable in \
        BFB_URL \
        ZT_BFB_REGISTRY_PORT \
        ZT_DPU_REBOOT_IMAGE; do
        if [ -z "${!variable:-}" ]; then
            echo "ERROR: Zero Trust installation requires ${variable}" >&2
            return 1
        fi
    done
    if [ -z "${ZT_DPU_DISCOVERY_NAME:-}" ]; then
        echo "ERROR: Zero Trust installation requires ZT_DPU_DISCOVERY_NAME" >&2
        return 1
    fi
    if [ "${VM_COUNT}" -gt 1 ] && [ -z "${HYPERSHIFT_API_IP:-}" ]; then
        echo "ERROR: Multi-node Zero Trust installation requires HYPERSHIFT_API_IP" >&2
        return 1
    fi

    echo "OK  Zero Trust mode validation passed"
}

validate_host_trusted_mode() {
    if [ "${DPF_DEPLOYMENT_MODE:-}" != "host-trusted" ]; then
        echo "ERROR: make all requires DPF_DEPLOYMENT_MODE=host-trusted; use make all-zt for Zero Trust" >&2
        return 1
    fi

    echo "OK  Host-trusted mode validation passed"
}

validate_post_install_manifest_dirs() {
    is_dpf_profile || return 0

    if [ ! -d "${POST_INSTALL_DIR}" ]; then
        echo "Error: Post-installation directory not found: ${POST_INSTALL_DIR}" >&2
        return 1
    fi
    if [ ! -d "${COMMON_POST_INSTALL_DIR}" ]; then
        echo "Error: Common post-installation directory not found: ${COMMON_POST_INSTALL_DIR}" >&2
        return 1
    fi
    if ! [[ "${NUM_VFS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: NUM_VFS must be a positive integer" >&2
        return 1
    fi

    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        if [ ! -d "${ZERO_TRUST_POST_INSTALL_DIR}" ]; then
            echo "Error: Zero Trust post-installation directory not found: ${ZERO_TRUST_POST_INSTALL_DIR}" >&2
            return 1
        fi
        return 0
    fi

    if [ ! -d "${HOST_TRUSTED_POST_INSTALL_DIR}" ]; then
        echo "Error: Host-trusted post-installation directory not found: ${HOST_TRUSTED_POST_INSTALL_DIR}" >&2
        return 1
    fi
}

# Validate aicli connectivity via the Red Hat Assisted Installer console.
# aicli uses HOME to find ~/.aicli/offlinetoken.txt. Override with AICLI_HOME.
validate_aicli() {
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
}

# When PAYLOAD_URL is set (e.g. by Prow), derive OPENSHIFT_VERSION and
# OCP_RELEASE_IMAGE from the release payload instead of using .env defaults.
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
    local _multi_image="quay.io/openshift-release-dev/ocp-release:${_payload_version}-multi"
    if oc adm release info "${_oc_registry_flags[@]}" "$_multi_image" &>/dev/null; then
        export OCP_RELEASE_IMAGE="$_multi_image"
    else
        export OCP_RELEASE_IMAGE="$PAYLOAD_URL"
    fi
    echo "PAYLOAD_URL set: OPENSHIFT_VERSION=${OPENSHIFT_VERSION}, OCP_RELEASE_IMAGE=${OCP_RELEASE_IMAGE}"
}

# Load environment variables from .env file and validate aicli connectivity
# (skip load/validate if already in Make context — the Makefile does
# `include .env` + `export`). Still strip quotes Make left on values;
# do not re-read .env or `make VAR=value` overrides would be clobbered.
if [ -z "${MAKELEVEL:-}" ]; then
    load_env
    validate_mtu

    if [ -z "${PAYLOAD_URL:-}" ]; then
        validate_aicli
    fi
else
    _strip_exported_env_quotes
fi

validate_deployment_profile

# Computed / conditional variables — derived from .env values at runtime.
# Only evaluate when sourced by other scripts (not when executed directly for
# standalone commands like validate-env-files / generate-env).
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Compatibility default for .env files generated before deployment profiles
    # were introduced.
    DPF_DEPLOYMENT_MODE=${DPF_DEPLOYMENT_MODE:-host-trusted}
    case "${DPF_DEPLOYMENT_MODE}" in
        host-trusted|zero-trust)
            ;;
        *)
            echo "Error: DPF_DEPLOYMENT_MODE must be 'host-trusted' or 'zero-trust'. Current value: ${DPF_DEPLOYMENT_MODE}" >&2
            exit 1
            ;;
    esac

    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        if [ "${VM_COUNT}" -eq 1 ]; then
            HYPERSHIFT_API_IP=""
            export HYPERSHIFT_API_IP
        fi

        validate_zero_trust_mode || exit 1
    fi

    MANIFESTS_DIR=${MANIFESTS_DIR:-manifests}
    POST_INSTALL_DIR="${MANIFESTS_DIR}/post-installation"
    COMMON_POST_INSTALL_DIR="${POST_INSTALL_DIR}/common"
    HOST_TRUSTED_POST_INSTALL_DIR="${POST_INSTALL_DIR}/host-trusted"
    ZERO_TRUST_POST_INSTALL_DIR="${POST_INSTALL_DIR}/zero-trust"
    validate_post_install_manifest_dirs || exit 1

    HELM_CHARTS_DIR=${HELM_CHARTS_DIR:-"$MANIFESTS_DIR/helm-charts-values"}
    HOST_CLUSTER_API=${HOST_CLUSTER_API:-"api.$CLUSTER_NAME.$BASE_DOMAIN"}
    HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CONTROL_PLANE_NAMESPACE:-"${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"}
    HOSTED_KUBECONFIG="${HOSTED_CLUSTER_NAME}.kubeconfig"

    if [ "$(readlink -m "${KUBECONFIG}")" = "$(readlink -m "${HOSTED_KUBECONFIG}")" ]; then
        echo "Error: Management KUBECONFIG '${KUBECONFIG}' must differ from hosted-cluster kubeconfig '${HOSTED_KUBECONFIG}'" >&2
        exit 1
    fi

    if [ -n "${PAYLOAD_URL:-}" ]; then
        resolve_payload
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
    if is_dpf_profile && [ -z "${OVN_KUBERNETES_IMAGE_TAG:-}" ] && command -v oc &>/dev/null; then
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
    if [ "${ARGUS_ENABLED}" != "true" ] && [ "${ARGUS_ENABLED}" != "false" ]; then
        echo "Error: ARGUS_ENABLED must be true or false (got '${ARGUS_ENABLED}')" >&2
        return 1
    fi
    ARGUS_CHART_VERSION=${ARGUS_CHART_VERSION:-1.5.0}
    ARGUS_HELM_REPO_URL=${ARGUS_HELM_REPO_URL:-${DPF_HELM_REPO_URL}}
    ARGUS_IMAGE=${ARGUS_IMAGE:-nvcr.io/nvidia/doca/doca_argus:1.5.0-doca3.5.0}
    ARGUS_IMAGE_PULL_SECRET=${ARGUS_IMAGE_PULL_SECRET:-dpf-pull-secret}
    ARGUS_TELEMETRY_NODE_PORT=${ARGUS_TELEMETRY_NODE_PORT:-30224}

    resolve_dpf_storage_class

    if [ "${ARGUS_ENABLED}" = "true" ]; then
        validate_argus_config || return 1
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
        validate-zt-inventory)
            validate_zero_trust_dpu_inventory
            ;;
        validate-zt-mode)
            validate_zero_trust_mode
            ;;
        validate-host-trusted-mode)
            validate_host_trusted_mode
            ;;
        *)
            echo "ERROR: Unknown command: $command"
            echo "Available commands: validate-env-files, generate-env, validate-env-test-files, generate-env-test, validate-zt-inventory, validate-zt-mode, validate-host-trusted-mode"
            exit 1
            ;;
    esac
fi
