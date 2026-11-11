#!/bin/bash

# Exit on error
set -e

# Prevent double sourcing (return only when sourced; direct invocations still run subcommands)
if [ -n "${ENV_SH_SOURCED:-}" ] && [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
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

# Canonicalize a path portably: `readlink -m` is GNU-only (BSD readlink and
# realpath on macOS reject it and require the file to exist). Resolve the file
# when it exists, else canonicalize its parent directory.
canonical_path() {
    local p="$1" dir
    if [ -e "${p}" ]; then
        readlink -f "${p}" 2>/dev/null && return 0
    fi
    case "${p}" in
        /*) ;;
        *) p="${PWD}/${p}" ;;
    esac
    dir="$(dirname "${p}")"
    if [ -d "${dir}" ]; then
        dir="$(cd "${dir}" && pwd -P)"
        p="${dir%/}/$(basename "${p}")"
    fi
    printf '%s\n' "${p}"
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

# -----------------------------------------------------------------------------
# Zero Trust tenant HostedCluster (make deploy-zt-tenant-cluster)
# -----------------------------------------------------------------------------

is_valid_dns_label() {
    local value="$1"
    [ "${#value}" -le 63 ] && [[ "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

is_valid_dns_subdomain() {
    local value="$1"
    [ "${#value}" -le 253 ] &&
        [[ "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]
}

is_valid_ipv4_cidr() {
    local cidr="$1" prefix
    case "${cidr}" in
        */*) ;;
        *) return 1 ;;
    esac
    prefix="${cidr##*/}"
    [[ "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
    [ "$((10#${prefix}))" -le 32 ] || return 1
    _ipv4_to_integer "${cidr%/*}" >/dev/null
}

# Resolve the SSH public key used as InfraEnv.sshAuthorizedKey. Echoes the path
# on success; the diagnostic goes to stderr because callers capture stdout.
_tenant_ssh_key_path() {
    local key_path="${SSH_PUBLIC_KEY_FILE:-${SSH_KEY:-}}"
    # Tilde is not expanded for quoted values sourced from .env.
    key_path="${key_path/#\~/${HOME}}"
    if [ -z "${key_path}" ] || [ ! -f "${key_path}" ]; then
        echo "ERROR: SSH public key not found (set SSH_KEY or SSH_PUBLIC_KEY_FILE to a .pub path)" >&2
        return 1
    fi
    if [[ "${key_path}" != *.pub ]]; then
        # Same rule as ensure_ssh_key_in_home: this file becomes InfraEnv
        # sshAuthorizedKey, so a private key must never be used here.
        echo "ERROR: SSH key '${key_path}' is not a .pub file (set SSH_KEY or SSH_PUBLIC_KEY_FILE to the public key)" >&2
        return 1
    fi
    echo "${key_path}"
}

# Two kubeconfigs that resolve to the same file would clobber each other, so
# every derived cluster needs its own path.
_require_distinct_kubeconfigs() {
    local a="$1" a_label="$2" b="$3" b_label="$4"
    [ -n "${a}" ] && [ -n "${b}" ] || return 0
    if [ "$(canonical_path "${a}")" = "$(canonical_path "${b}")" ]; then
        echo "Error: ${a_label} '${a}' must differ from ${b_label} '${b}'" >&2
        return 1
    fi
}

# Assisted Installer RHCOS artifacts for the tenant InfraEnv. Defaults and
# validation live here; zt-tenant-cluster.sh only consumes the values.
# Only x86_64 and aarch64 are supported: there is no multi-arch RHCOS live ISO
# for Assisted discovery, and the tenant workers are one of those two builds.
_tenant_resolve_rhcos_artifacts() {
    local mirror_arch

    case "${ZT_TENANT_RHCOS_CPU_ARCHITECTURE}" in
        x86_64 | amd64)
            ZT_TENANT_RHCOS_OSIMAGE_ARCH=x86_64
            ZT_TENANT_NODEPOOL_ARCH=amd64
            mirror_arch=x86_64
            ;;
        aarch64 | arm64)
            ZT_TENANT_RHCOS_OSIMAGE_ARCH=arm64
            ZT_TENANT_NODEPOOL_ARCH=arm64
            mirror_arch=aarch64
            ;;
        *)
            # validate_zt_tenant_configuration reports the invalid value.
            ZT_TENANT_RHCOS_OSIMAGE_ARCH=""
            ZT_TENANT_NODEPOOL_ARCH=""
            return 0
            ;;
    esac

    # AgentServiceConfig osImages.openshiftVersion is major.minor (e.g. 4.22).
    ZT_TENANT_OPENSHIFT_VERSION_MINOR="${ZT_TENANT_OPENSHIFT_VERSION_MINOR%%-multi}"
    ZT_TENANT_OPENSHIFT_VERSION_MINOR="$(echo "${ZT_TENANT_OPENSHIFT_VERSION_MINOR}" | awk -F. '{if (NF >= 2) print $1"."$2; else print $0}')"

    if [ -n "${ZT_TENANT_RHCOS_ISO_URL}" ] || [ -n "${ZT_TENANT_RHCOS_ROOTFS_URL}" ] ||
        [ -n "${ZT_TENANT_RHCOS_VERSION}" ]; then
        if [ -z "${ZT_TENANT_RHCOS_ISO_URL}" ] || [ -z "${ZT_TENANT_RHCOS_ROOTFS_URL}" ] ||
            [ -z "${ZT_TENANT_RHCOS_VERSION}" ]; then
            echo "Error: ZT_TENANT_RHCOS_ISO_URL, ZT_TENANT_RHCOS_ROOTFS_URL and ZT_TENANT_RHCOS_VERSION must be set together" >&2
            return 1
        fi
        return 0
    fi

    # Only the tenant flow needs the mirror lookups; other targets must not
    # pay for them.
    [ "$(basename "${0:-}")" = "zt-tenant-cluster.sh" ] || return 0

    # The mirror publishes the RHEL 9 based RHCOS under the plain minor
    # (<minor>/latest). The 4.22-el10 tree is the RHEL 10 variant and is not
    # what the tenant cluster runs.
    local base
    base="https://mirror.openshift.com/pub/openshift-v4/${mirror_arch}/dependencies/rhcos/${ZT_TENANT_OPENSHIFT_VERSION_MINOR}/latest"

    ZT_TENANT_RHCOS_ISO_URL="${base}/rhcos-live-iso.${mirror_arch}.iso"
    ZT_TENANT_RHCOS_ROOTFS_URL="${base}/rhcos-live-rootfs.${mirror_arch}.img"
    ZT_TENANT_RHCOS_VERSION="$(curl -fsSL "${base}/rhcos-id.txt" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "${ZT_TENANT_RHCOS_VERSION}" ] || ZT_TENANT_RHCOS_VERSION="${ZT_TENANT_OPENSHIFT_VERSION_MINOR}"
    echo "Using mirror RHCOS for Assisted: ${ZT_TENANT_RHCOS_VERSION} (${ZT_TENANT_RHCOS_ISO_URL})"
}

# Offline check of everything the tenant HostedCluster flow consumes, run at the
# start of `make deploy-zt-tenant-cluster` before any cluster calls are made.
validate_zt_tenant_configuration() {
    local host dpu_count variable kc_dir

    if [ "${DPF_DEPLOYMENT_MODE:-}" != "zero-trust" ]; then
        echo "ERROR: deploy-zt-tenant-cluster requires DPF_DEPLOYMENT_MODE=zero-trust" >&2
        return 1
    fi
    if [ "${HYPERSHIFT_INSTALL_METHOD:-}" != "mce" ]; then
        echo "ERROR: deploy-zt-tenant-cluster requires HYPERSHIFT_INSTALL_METHOD=mce (shared MCE HyperShift + Assisted)" >&2
        return 1
    fi

    # Names: they become namespaces, object names and label values. HyperShift
    # prefixes the API/ingress hosts with the cluster name, so the tenant base
    # domain may equal BASE_DOMAIN.
    if ! is_valid_dns_label "${ZT_TENANT_CLUSTER_NAME:-}"; then
        echo "ERROR: ZT_TENANT_CLUSTER_NAME '${ZT_TENANT_CLUSTER_NAME:-}' must be a lowercase DNS-1123 label (<=63 chars); it is used in the agent namespace ${CLUSTERS_NAMESPACE}-<name>" >&2
        return 1
    fi
    if [ "${ZT_TENANT_CLUSTER_NAME}" = "${HOSTED_CLUSTER_NAME:-}" ]; then
        echo "ERROR: ZT_TENANT_CLUSTER_NAME must differ from HOSTED_CLUSTER_NAME '${HOSTED_CLUSTER_NAME:-}' (namespace and kubeconfig collision)" >&2
        return 1
    fi
    if ! is_valid_dns_subdomain "${ZT_TENANT_BASE_DOMAIN:-}"; then
        echo "ERROR: ZT_TENANT_BASE_DOMAIN '${ZT_TENANT_BASE_DOMAIN:-}' must be a lowercase DNS name without a scheme or trailing dot" >&2
        return 1
    fi
    for variable in ZT_TENANT_PULL_SECRET_NAME ZT_TENANT_NODEPOOL_NAME ZT_TENANT_INFRAENV_NAME; do
        if ! is_valid_dns_label "${!variable:-}"; then
            echo "ERROR: ${variable} '${!variable:-}' must be a lowercase DNS-1123 label (<=63 chars)" >&2
            return 1
        fi
    done
    # Label keys may omit the DNS prefix (default here includes one).
    if [[ ! "${ZT_TENANT_AGENT_LABEL_KEY:-}" =~ ^([a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$ ]]; then
        echo "ERROR: ZT_TENANT_AGENT_LABEL_KEY '${ZT_TENANT_AGENT_LABEL_KEY:-}' must be a valid label key (name or prefix/name, e.g. openshift-dpf.io/zt-tenant-cluster)" >&2
        return 1
    fi

    for variable in ZT_TENANT_CLUSTER_NETWORK_CIDR ZT_TENANT_SERVICE_NETWORK_CIDR; do
        if ! is_valid_ipv4_cidr "${!variable:-}"; then
            echo "ERROR: ${variable} '${!variable:-}' must be a valid IPv4 CIDR (e.g. 10.128.0.0/14)" >&2
            return 1
        fi
    done

    # Only the two architectures with public RHCOS live ISO artifacts are
    # supported; there is no multi-arch discovery image.
    case "${ZT_TENANT_RHCOS_CPU_ARCHITECTURE}" in
        x86_64 | amd64 | aarch64 | arm64) ;;
        *)
            echo "ERROR: ZT_TENANT_RHCOS_CPU_ARCHITECTURE '${ZT_TENANT_RHCOS_CPU_ARCHITECTURE}' must be x86_64 or aarch64 (arm64)" >&2
            return 1
            ;;
    esac

    # env.sh trims an explicit value to major.minor (4.22.0 -> 4.22).
    if [ -n "${ZT_TENANT_OPENSHIFT_VERSION_MINOR:-}" ] &&
        [[ ! "${ZT_TENANT_OPENSHIFT_VERSION_MINOR}" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: ZT_TENANT_OPENSHIFT_VERSION_MINOR '${ZT_TENANT_OPENSHIFT_VERSION_MINOR}' must be major.minor (e.g. 4.22)" >&2
        return 1
    fi

    for variable in ZT_TENANT_RHCOS_ISO_URL ZT_TENANT_RHCOS_ROOTFS_URL; do
        if [ -n "${!variable:-}" ] && [[ ! "${!variable}" =~ ^https?:// ]]; then
            echo "ERROR: ${variable} '${!variable}' must be an http(s) URL" >&2
            return 1
        fi
    done

    # The AgentServiceConfig osImage needs all four; env.sh fills them from the
    # mirror for make deploy-zt-tenant-cluster when none are set in .env.
    for variable in ZT_TENANT_RHCOS_ISO_URL ZT_TENANT_RHCOS_ROOTFS_URL ZT_TENANT_RHCOS_VERSION ZT_TENANT_OPENSHIFT_VERSION_MINOR; do
        if [ -z "${!variable:-}" ]; then
            echo "ERROR: ${variable} is required for the tenant AgentServiceConfig osImage (no mirror autofill for architecture '${ZT_TENANT_RHCOS_CPU_ARCHITECTURE}')" >&2
            return 1
        fi
    done

    export ZT_TENANT_OCP_RELEASE_IMAGE="${ZT_TENANT_OCP_RELEASE_IMAGE:-${OCP_RELEASE_IMAGE}}"
    if [ -z "${ZT_TENANT_OCP_RELEASE_IMAGE:-}" ]; then
        echo "ERROR: OCP_RELEASE_IMAGE is required for tenant HostedCluster (set OPENSHIFT_VERSION, PAYLOAD_URL, or OCP_RELEASE_IMAGE in .env)" >&2
        return 1
    fi

    if [ -z "${ETCD_STORAGE_CLASS:-}" ]; then
        echo "ERROR: ETCD_STORAGE_CLASS is required for the tenant HostedCluster etcd (resolved from STORAGE_TYPE; set it explicitly when SKIP_DEPLOY_STORAGE=true)" >&2
        return 1
    fi

    if [ -z "${ZT_TENANT_KUBECONFIG:-}" ]; then
        echo "ERROR: ZT_TENANT_KUBECONFIG is required (path the tenant kubeconfig is written to)" >&2
        return 1
    fi
    if [ -d "${ZT_TENANT_KUBECONFIG}" ]; then
        echo "ERROR: ZT_TENANT_KUBECONFIG '${ZT_TENANT_KUBECONFIG}' is a directory" >&2
        return 1
    fi
    kc_dir="$(dirname "${ZT_TENANT_KUBECONFIG}")"
    if [ ! -d "${kc_dir}" ]; then
        echo "ERROR: ZT_TENANT_KUBECONFIG directory '${kc_dir}' does not exist (the tenant kubeconfig is written there at the end of the install)" >&2
        return 1
    fi
    if [ ! -w "${kc_dir}" ]; then
        echo "ERROR: ZT_TENANT_KUBECONFIG directory '${kc_dir}' is not writable" >&2
        return 1
    fi

    dpu_count=0
    while IFS= read -r host; do
        dpu_count=$((dpu_count + 1))
    done < <(list_zero_trust_dpu_hosts)

    if [ "${dpu_count}" -lt 1 ]; then
        echo "ERROR: No Zero Trust DPU hosts (WORKER_<N>_DPU_BMC_IPS); cannot derive tenant worker count" >&2
        return 1
    fi

    while IFS= read -r host; do
        for variable in "WORKER_${host}_BMC_IP" "WORKER_${host}_BMC_USER" "WORKER_${host}_BMC_PASSWORD" "WORKER_${host}_BOOT_MAC" "WORKER_${host}_ROOT_DEVICE"; do
            if [ -z "${!variable:-}" ]; then
                echo "ERROR: Missing ${variable} for tenant BareMetalHost (same BMC as DPU host ${host})" >&2
                return 1
            fi
        done
    done < <(list_zero_trust_dpu_hosts)

    # The InfraEnv/HostedCluster needs an SSH public key; fail here instead of
    # after the control plane has been created.
    _tenant_ssh_key_path >/dev/null || return 1

    echo "OK  Tenant cluster configuration validation passed"
}

validate_zero_trust_mode() {
    local variable

    if [ "${DPF_DEPLOYMENT_MODE:-}" != "zero-trust" ]; then
        echo "ERROR: Zero Trust validation requires DPF_DEPLOYMENT_MODE=zero-trust" >&2
        return 1
    fi
    case "${HYPERSHIFT_INSTALL_METHOD:-}" in
        binary|mce)
            ;;
        *)
            echo "ERROR: Zero Trust installation requires HYPERSHIFT_INSTALL_METHOD=binary or mce (got '${HYPERSHIFT_INSTALL_METHOD:-}')" >&2
            return 1
            ;;
    esac
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

    # Apply the documented default at runtime, not only in env.defaults: an
    # .env generated before HYPERSHIFT_INSTALL_METHOD existed leaves it empty,
    # which validate_zero_trust_mode would reject as an invalid value.
    HYPERSHIFT_INSTALL_METHOD="${HYPERSHIFT_INSTALL_METHOD:-binary}"
    export HYPERSHIFT_INSTALL_METHOD

    if [ "${DPF_DEPLOYMENT_MODE}" = "zero-trust" ]; then
        if [ "${VM_COUNT}" -eq 1 ]; then
            HYPERSHIFT_API_IP=""
            export HYPERSHIFT_API_IP
        fi

        validate_zero_trust_mode || exit 1
    fi

    MANIFESTS_DIR=${MANIFESTS_DIR:-manifests}
    GENERATED_DIR=${GENERATED_DIR:-"${MANIFESTS_DIR}/generated"}
    CLUSTERS_NAMESPACE=${CLUSTERS_NAMESPACE:-clusters}
    POST_INSTALL_DIR="${MANIFESTS_DIR}/post-installation"
    COMMON_POST_INSTALL_DIR="${POST_INSTALL_DIR}/common"
    HOST_TRUSTED_POST_INSTALL_DIR="${POST_INSTALL_DIR}/host-trusted"
    ZERO_TRUST_POST_INSTALL_DIR="${POST_INSTALL_DIR}/zero-trust"
    validate_post_install_manifest_dirs || exit 1

    HELM_CHARTS_DIR=${HELM_CHARTS_DIR:-"$MANIFESTS_DIR/helm-charts-values"}
    HOST_CLUSTER_API=${HOST_CLUSTER_API:-"api.$CLUSTER_NAME.$BASE_DOMAIN"}
    HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CONTROL_PLANE_NAMESPACE:-"${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"}
    HOSTED_KUBECONFIG="${HOSTED_CLUSTER_NAME}.kubeconfig"

    # Tenant HostedCluster (physical workers); used by make deploy-zt-tenant-cluster
    ZT_TENANT_CLUSTER_NAME=${ZT_TENANT_CLUSTER_NAME:-tenant}
    ZT_TENANT_KUBECONFIG=${ZT_TENANT_KUBECONFIG:-tenant.kubeconfig}
    ZT_TENANT_GENERATED_DIR="${GENERATED_DIR}/zt-tenant"
    # Runtime defaults mirror ci/env.defaults, so a .env generated before a
    # ZT_TENANT_* variable existed still validates and deploys.
    ZT_TENANT_CLUSTER_NETWORK_CIDR=${ZT_TENANT_CLUSTER_NETWORK_CIDR:-10.128.0.0/14}
    ZT_TENANT_SERVICE_NETWORK_CIDR=${ZT_TENANT_SERVICE_NETWORK_CIDR:-172.30.0.0/16}
    ZT_TENANT_OPENSHIFT_VERSION_MINOR=${ZT_TENANT_OPENSHIFT_VERSION_MINOR:-${OPENSHIFT_VERSION%%-*}}
    ZT_TENANT_RHCOS_CPU_ARCHITECTURE=${ZT_TENANT_RHCOS_CPU_ARCHITECTURE:-x86_64}
    ZT_TENANT_PULL_SECRET_NAME=${ZT_TENANT_PULL_SECRET_NAME:-zt-tenant-pull-secret}
    ZT_TENANT_NODEPOOL_NAME=${ZT_TENANT_NODEPOOL_NAME:-tenant-workers}
    ZT_TENANT_INFRAENV_NAME=${ZT_TENANT_INFRAENV_NAME:-zt-tenant-infraenv}
    ZT_TENANT_AGENT_LABEL_KEY=${ZT_TENANT_AGENT_LABEL_KEY:-openshift-dpf.io/zt-tenant-cluster}

    _require_distinct_kubeconfigs "${KUBECONFIG}" "Management KUBECONFIG" \
        "${HOSTED_KUBECONFIG}" "hosted-cluster kubeconfig" || exit 1
    _require_distinct_kubeconfigs "${KUBECONFIG}" "Management KUBECONFIG" \
        "${ZT_TENANT_KUBECONFIG}" "tenant kubeconfig" || exit 1
    _require_distinct_kubeconfigs "${HOSTED_KUBECONFIG}" "DPU hosted kubeconfig" \
        "${ZT_TENANT_KUBECONFIG}" "tenant kubeconfig" || exit 1

    if [ -n "${PAYLOAD_URL:-}" ]; then
        resolve_payload
    fi

    # Tenant HostedCluster release matches hub OCP unless overridden manually in .env
    export ZT_TENANT_OCP_RELEASE_IMAGE="${ZT_TENANT_OCP_RELEASE_IMAGE:-${OCP_RELEASE_IMAGE}}"

    _tenant_resolve_rhcos_artifacts || exit 1
    export ZT_TENANT_GENERATED_DIR ZT_TENANT_OPENSHIFT_VERSION_MINOR ZT_TENANT_RHCOS_CPU_ARCHITECTURE
    export ZT_TENANT_RHCOS_ISO_URL ZT_TENANT_RHCOS_ROOTFS_URL ZT_TENANT_RHCOS_VERSION
    export ZT_TENANT_RHCOS_OSIMAGE_ARCH ZT_TENANT_NODEPOOL_ARCH

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
