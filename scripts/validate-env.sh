#!/bin/bash

# Explicit environment validation entry point and sourceable validation helpers.
set -e
set -o pipefail

_do_validate_env_files() {
    local defaults_file="$1" template_file="$2" required_file="$3" output_file="$4"

    local defaults template required known missing extra count
    defaults=$(grep -oE '^[[:alnum:]_]+' "$defaults_file" | sort)
    template=$(grep -oE '^[[:alnum:]_]+' "$template_file" | sort)
    required=$(grep -v '^[[:space:]]*#' "$required_file" |
        grep -Eo '[{][[:alnum:]_]+:[?]' | sed 's/^[{]//; s/:?$//' | sort)
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
# Checked during preflight so invalid settings fail before deployment starts.
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

validate_aicli() {
    local original_home="${ENV_SH_ORIGINAL_HOME:-$HOME}"
    AICLI_HOME=${AICLI_HOME:-$original_home}
    if [[ "$AICLI_HOME" != "$original_home" ]] && [[ ! -f "${AICLI_HOME}/.aicli/offlinetoken.txt" ]]; then
        echo "Error: ${AICLI_HOME}/.aicli/offlinetoken.txt not found." >&2
        exit 1
    fi
    export HOME="${AICLI_HOME}"
    if ! aicli list clusters &>/dev/null; then
        echo "Error: aicli list clusters failed. Check token at ${AICLI_HOME}/.aicli/offlinetoken.txt and connectivity." >&2
        exit 1
    fi
}

validate_deployment_mode() {
    case "${DPF_DEPLOYMENT_MODE:-host-trusted}" in
        host-trusted|zero-trust)
            ;;
        *)
            echo "Error: DPF_DEPLOYMENT_MODE must be 'host-trusted' or 'zero-trust'. Current value: ${DPF_DEPLOYMENT_MODE}" >&2
            return 1
            ;;
    esac
}

validate_argus_enabled_value() {
    if [ "${ARGUS_ENABLED:-false}" != "true" ] && [ "${ARGUS_ENABLED:-false}" != "false" ]; then
        echo "Error: ARGUS_ENABLED must be true or false (got '${ARGUS_ENABLED}')" >&2
        return 1
    fi
}

_canonicalize_path() {
    local path="$1" resolved component
    local -a components=() normalized=()

    [ -n "${path}" ] || return 1

    if resolved=$(readlink -m "${path}" 2>/dev/null); then
        printf '%s\n' "${resolved}"
        return 0
    fi

    if resolved=$(realpath "${path}" 2>/dev/null); then
        printf '%s\n' "${resolved}"
        return 0
    fi

    case "${path}" in
        /*) ;;
        *) path="${PWD}/${path}" ;;
    esac

    IFS='/' read -r -a components <<< "${path}"
    for component in "${components[@]}"; do
        case "${component}" in
            ""|.)
                ;;
            ..)
                if [ "${#normalized[@]}" -gt 0 ]; then
                    normalized=("${normalized[@]:0:${#normalized[@]}-1}")
                fi
                ;;
            *)
                normalized+=("${component}")
                ;;
        esac
    done

    local IFS=/
    printf '/%s\n' "${normalized[*]}"
}

validate_management_kubeconfig() {
    local management_kubeconfig hosted_kubeconfig
    management_kubeconfig="$(_canonicalize_path "${KUBECONFIG}")" || return 1
    hosted_kubeconfig="$(_canonicalize_path "${HOSTED_KUBECONFIG}")" || return 1

    if [ "${management_kubeconfig}" = "${hosted_kubeconfig}" ]; then
        echo "Error: Management KUBECONFIG '${KUBECONFIG}' must differ from hosted-cluster kubeconfig '${HOSTED_KUBECONFIG}'" >&2
        return 1
    fi
}

validate_storage_configuration() {
    is_dpf_profile || return 0

    if [ "${SKIP_DEPLOY_STORAGE}" = "true" ] && [ -z "${ETCD_STORAGE_CLASS}" ]; then
        echo "Error: SKIP_DEPLOY_STORAGE=true requires ETCD_STORAGE_CLASS to be set in .env to your existing StorageClass name." >&2
        echo "Create the StorageClass in the cluster (e.g. via your storage operator), then set ETCD_STORAGE_CLASS in .env." >&2
        return 1
    fi
}

validate_environment() {
    validate_mtu
    validate_deployment_profile
    validate_deployment_mode
    # Zero Trust's focused mode validation checks the delay with Redfish config.
    if [ "${DPF_DEPLOYMENT_MODE}" != "zero-trust" ]; then
        validate_worker_power_on_delay
    fi
    validate_storage_configuration
    validate_post_install_manifest_dirs
    validate_management_kubeconfig
    validate_argus_enabled_value
    if [ "${ARGUS_ENABLED}" = "true" ]; then
        validate_argus_config
    fi
    if [ -z "${PAYLOAD_URL:-}" ]; then
        validate_aicli
    fi

    echo "OK  Environment validation passed"
}

validate_worker_power_on_workflow() {
    case "${DPF_DEPLOYMENT_MODE:-host-trusted}" in
        host-trusted)
            validate_environment
            ;;
        zero-trust)
            validate_zero_trust_mode
            ;;
        *)
            validate_deployment_mode
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    command="${1:-preflight}"
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    case "${command}" in
        validate-env-files)
            validate_env_files
            ;;
        validate-env-test-files)
            validate_env_test_files
            ;;
        *)
            unset ENV_SH_SOURCED
            ENV_SH_VALIDATION_ONLY=true
            source "${script_dir}/env.sh"
            unset ENV_SH_VALIDATION_ONLY
            case "${command}" in
                preflight|validate-environment)
                    validate_environment
                    ;;
                validate-mtu)
                    validate_mtu
                    ;;
                validate-deployment-profile)
                    validate_deployment_profile
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
                validate-worker-power-on-delay)
                    validate_worker_power_on_delay
                    ;;
                validate-worker-power-on)
                    validate_worker_power_on_workflow
                    ;;
                require-argus-enabled)
                    require_argus_enabled
                    ;;
                *)
                    echo "ERROR: Unknown command: ${command}" >&2
                    echo "Available commands: preflight, validate-env-files, validate-env-test-files, validate-mtu, validate-deployment-profile, validate-zt-inventory, validate-zt-mode, validate-host-trusted-mode, validate-worker-power-on-delay, validate-worker-power-on, require-argus-enabled" >&2
                    exit 1
                    ;;
            esac
            ;;
    esac
fi
