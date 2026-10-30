#!/usr/bin/env bash
# Read, set, and validate UEFI Secure Boot across physical workers via BMC Redfish.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

usage() {
    cat <<'EOF'
Usage:
  scripts/worker-secure-boot.sh show <worker-index>
  scripts/worker-secure-boot.sh set <worker-index> enable|disable
  scripts/worker-secure-boot.sh wait <worker-index> enable|disable [timeout-minutes]
  scripts/worker-secure-boot.sh all enable|disable [timeout-minutes]

Examples:
  scripts/worker-secure-boot.sh show 1
  scripts/worker-secure-boot.sh set 1 enable
  scripts/worker-secure-boot.sh wait 1 enable 15
  scripts/worker-secure-boot.sh all enable 15

Reads WORKER_<index>_BMC_IP, WORKER_<index>_BMC_USER, and
WORKER_<index>_BMC_PASSWORD from .env (or the process environment).
An optional WORKER_<index>_REDFISH_SYSTEM_PATH can specify the Redfish
ComputerSystem resource path, for example /redfish/v1/Systems/System.Embedded.1.
It is required if the BMC lists more than one system. TLS certificates are
verified by default; set REDFISH_CA_BUNDLE to a trusted CA bundle, or explicitly
set REDFISH_INSECURE=true for a trusted lab network with self-signed certificates.

The set command prechecks one server and changes/reboots it only when needed.
The all command prechecks workers 1..WORKER_COUNT, applies only needed changes,
then waits for every worker to report the requested current-boot state. The default
reset is ForceRestart to avoid waiting for graceful OS shutdown. The default wait
timeout is 15 minutes; polling is once per minute.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

load_worker_env() {
    local key value
    if [[ ! -r "${ENV_FILE}" ]]; then
        return 0
    fi

    while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
        [[ -z "${key:-}" || "${key}" == \\#* ]] && continue
        case "${key}" in
            WORKER_COUNT|WORKER_[0-9]*_BMC_IP|WORKER_[0-9]*_BMC_USER|WORKER_[0-9]*_BMC_PASSWORD|WORKER_[0-9]*_REDFISH_SYSTEM_PATH|REDFISH_CA_BUNDLE|REDFISH_INSECURE)
                value="${value%$'\r'}"
                value="${value#\"}"; value="${value%\"}"
                value="${value#\'}"; value="${value%\'}"
                # Preserve values explicitly supplied in the shell environment.
                if ! declare -p "${key}" >/dev/null 2>&1; then
                    printf -v "${key}" '%s' "${value}"
                fi
                export "${key}"
                ;;
        esac
    done < "${ENV_FILE}"
}

worker_value() {
    local key="WORKER_${2}_${1}"
    printf '%s' "${!key:-}"
}

CURL_CONFIG=""
RESPONSE_FILE=""
BMC_IP=""
BASE_URL=""
SYSTEM_PATH=""
SECURE_BOOT_PATH=""
RESET_TARGET=""
RESET_TYPE="ForceRestart"
POLL_INTERVAL_SECONDS=60
CONFIGURED_STATE=""
CURRENT_BOOT_STATE=""
SECURE_BOOT_MODE=""
PRECHECK_OPERATION=""

desired_boot_state() {
    if [[ "$1" == enable ]]; then
        printf 'enabled'
    else
        printf 'disabled'
    fi
}

worker_has_bmc_credentials() {
    local index="$1"
    [[ -n "$(worker_value BMC_IP "${index}")" && \
        -n "$(worker_value BMC_USER "${index}")" && \
        -n "$(worker_value BMC_PASSWORD "${index}")" ]]
}

is_worker_index() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_desired_state() {
    [[ "$1" == enable || "$1" == disable ]]
}

valid_redfish_path() {
    [[ "$1" == /redfish/v1/* && "$1" != *..* ]]
}

init_request_files() {
    [[ -n "${CURL_CONFIG}" ]] && return 0
    CURL_CONFIG="$(mktemp "${TMPDIR:-/tmp}/worker-redfish-curl.XXXXXX")"
    RESPONSE_FILE="$(mktemp "${TMPDIR:-/tmp}/worker-redfish-response.XXXXXX")"
    chmod 600 "${CURL_CONFIG}" "${RESPONSE_FILE}"
    trap 'rm -f "${CURL_CONFIG}" "${RESPONSE_FILE}"' EXIT
}

escape_curl_config() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "${value}"
}

redfish_request() {
    local method="$1" url="$2" output_file="$3" data="${4:-}"
    local http_code curl_status retry_delay attempt=1 max_attempts=3
    local request_timeout=30 remaining_before_request
    local -a args=()

    while (( attempt <= max_attempts )); do
        if [[ -n "${REDFISH_REQUEST_DEADLINE:-}" ]]; then
            remaining_before_request=$((REDFISH_REQUEST_DEADLINE - SECONDS))
            (( remaining_before_request > 0 )) || return 1
            request_timeout=30
            (( request_timeout > remaining_before_request )) && request_timeout="${remaining_before_request}"
        fi
        args=(
            --config "${CURL_CONFIG}"
            --silent
            --show-error
            --connect-timeout 5
            --max-time "${request_timeout}"
            --request "${method}"
            --header 'Accept: application/json'
            --output "${output_file}"
            --write-out '%{http_code}'
        )
        if [[ "${REDFISH_INSECURE:-false}" == true ]]; then
            args+=(--insecure)
        elif [[ -n "${REDFISH_CA_BUNDLE:-}" ]]; then
            args+=(--cacert "${REDFISH_CA_BUNDLE}")
        fi
        if [[ -n "${data}" ]]; then
            args+=(--header 'Content-Type: application/json' --data "${data}")
        fi
        curl_status=0
        http_code="$(curl "${args[@]}" "${url}")" || curl_status=$?
        if (( curl_status != 0 )); then
            [[ -s "${output_file}" ]] && cat "${output_file}" >&2
            return "${curl_status}"
        fi
        if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
            return 0
        fi
        if [[ "${method}" == GET && "${http_code}" == 503 && ${attempt} -lt ${max_attempts} ]]; then
            retry_delay="$(jq -r '[.error["@Message.ExtendedInfo"][]?.Message? | try capture("Retry in (?<seconds>[0-9]+) seconds").seconds] | first // empty' \
                "${output_file}" 2>/dev/null || true)"
            [[ "${retry_delay}" =~ ^[0-9]+$ ]] || retry_delay=5
            if [[ -n "${REDFISH_REQUEST_DEADLINE:-}" ]]; then
                remaining_before_request=$((REDFISH_REQUEST_DEADLINE - SECONDS))
                (( remaining_before_request > 0 )) || return 1
                (( retry_delay > remaining_before_request )) && retry_delay="${remaining_before_request}"
            fi
            printf 'Redfish GET %s returned HTTP 503; retrying in %s seconds (%s/%s)\n' \
                "${url}" "${retry_delay}" "${attempt}" "$((max_attempts - 1))" >&2
            sleep "${retry_delay}"
            if [[ -n "${REDFISH_REQUEST_DEADLINE:-}" ]] && \
                (( SECONDS >= REDFISH_REQUEST_DEADLINE )); then
                return 1
            fi
            attempt=$((attempt + 1))
            continue
        fi
        printf 'Redfish %s %s returned HTTP %s\n' "${method}" "${url}" "${http_code:-unknown}" >&2
        [[ -s "${output_file}" ]] && cat "${output_file}" >&2
        return 1
    done
}

prepare_worker_context() {
    local index="$1" bmc_user bmc_password
    BMC_IP="$(worker_value BMC_IP "${index}")"
    bmc_user="$(worker_value BMC_USER "${index}")"
    bmc_password="$(worker_value BMC_PASSWORD "${index}")"
    SYSTEM_PATH="$(worker_value REDFISH_SYSTEM_PATH "${index}")"

    worker_has_bmc_credentials "${index}" || {
        printf 'ERROR: WORKER_%s_BMC_IP, WORKER_%s_BMC_USER, and WORKER_%s_BMC_PASSWORD must be set\n' \
            "${index}" "${index}" "${index}" >&2
        return 1
    }
    [[ "${BMC_IP}" != *'/'* && "${BMC_IP}" != *$'\r'* && "${BMC_IP}" != *$'\n'* ]] || {
        printf 'ERROR: Invalid BMC IP value for worker %s\n' "${index}" >&2
        return 1
    }
    [[ "${bmc_user}" != *$'\r'* && "${bmc_user}" != *$'\n'* && \
        "${bmc_password}" != *$'\r'* && "${bmc_password}" != *$'\n'* ]] || {
        printf 'ERROR: BMC credentials for worker %s must not contain newline characters\n' "${index}" >&2
        return 1
    }
    case "${REDFISH_INSECURE:-false}" in
        true|false) ;;
        *)
            printf 'ERROR: REDFISH_INSECURE must be true or false\n' >&2
            return 1
            ;;
    esac
    if [[ -n "${REDFISH_CA_BUNDLE:-}" && \
        ( ! -f "${REDFISH_CA_BUNDLE}" || ! -r "${REDFISH_CA_BUNDLE}" ) ]]; then
        printf 'ERROR: REDFISH_CA_BUNDLE must point to a readable CA bundle\n' >&2
        return 1
    fi
    if [[ "${REDFISH_INSECURE:-false}" == true && -n "${REDFISH_CA_BUNDLE:-}" ]]; then
        printf 'ERROR: Set either REDFISH_CA_BUNDLE or REDFISH_INSECURE=true, not both\n' >&2
        return 1
    fi

    init_request_files
    printf 'user = "%s:%s"\n' "$(escape_curl_config "${bmc_user}")" \
        "$(escape_curl_config "${bmc_password}")" > "${CURL_CONFIG}"
    BASE_URL="https://${BMC_IP}"
}

resolve_worker_resources() {
    local index="$1" require_reset="$2" systems_url member_count
    if [[ -n "${SYSTEM_PATH}" ]]; then
        [[ "${SYSTEM_PATH}" == /redfish/v1/Systems/* ]] && valid_redfish_path "${SYSTEM_PATH}" || {
            printf 'ERROR: WORKER_%s_REDFISH_SYSTEM_PATH must be a Redfish Systems path\n' "${index}" >&2
            return 1
        }
    else
        systems_url="${BASE_URL}/redfish/v1/Systems"
        redfish_request GET "${systems_url}" "${RESPONSE_FILE}" || {
            printf 'ERROR: Could not read worker %s Redfish Systems collection\n' "${index}" >&2
            return 1
        }
        member_count="$(jq -r 'if (.Members | type) == "array" then (.Members | length) else 0 end' \
            "${RESPONSE_FILE}")" || return 1
        if [[ "${member_count}" != 1 ]]; then
            if (( member_count > 1 )); then
                printf 'ERROR: Worker %s BMC lists %s systems; set WORKER_%s_REDFISH_SYSTEM_PATH to select one explicitly\n' \
                    "${index}" "${member_count}" "${index}" >&2
            else
                printf 'ERROR: Worker %s BMC Systems collection contains no systems\n' "${index}" >&2
            fi
            return 1
        fi
        SYSTEM_PATH="$(jq -r '.Members[0]["@odata.id"] // empty' "${RESPONSE_FILE}")" || return 1
        [[ "${SYSTEM_PATH}" == /redfish/v1/Systems/* ]] && valid_redfish_path "${SYSTEM_PATH}" || {
            printf 'ERROR: Redfish Systems collection returned an invalid system path for worker %s\n' "${index}" >&2
            return 1
        }
    fi

    redfish_request GET "${BASE_URL}${SYSTEM_PATH}" "${RESPONSE_FILE}" || {
        printf 'ERROR: Could not read worker %s system resource\n' "${index}" >&2
        return 1
    }
    SECURE_BOOT_PATH="$(jq -r '.SecureBoot["@odata.id"] // empty' "${RESPONSE_FILE}")" || return 1

    if [[ "${require_reset}" == true ]]; then
        RESET_TARGET="$(jq -r '.Actions["#ComputerSystem.Reset"].target // empty' "${RESPONSE_FILE}")" || return 1
        valid_redfish_path "${RESET_TARGET}" || {
            printf 'ERROR: Worker %s does not expose a valid ComputerSystem.Reset action\n' "${index}" >&2
            return 1
        }
        if jq -e '.Actions["#ComputerSystem.Reset"]["ResetType@Redfish.AllowableValues"] | type == "array"' \
            "${RESPONSE_FILE}" >/dev/null; then
            jq -e --arg reset_type "${RESET_TYPE}" '.Actions["#ComputerSystem.Reset"]["ResetType@Redfish.AllowableValues"] | index($reset_type) != null' \
                "${RESPONSE_FILE}" >/dev/null || {
                printf 'ERROR: Worker %s BMC does not advertise %s\n' "${index}" "${RESET_TYPE}" >&2
                return 1
            }
        fi
    fi

    if [[ -z "${SECURE_BOOT_PATH}" ]]; then
        SECURE_BOOT_PATH="${SYSTEM_PATH%/}/SecureBoot"
    fi
    valid_redfish_path "${SECURE_BOOT_PATH}" || {
        printf 'ERROR: Worker %s BMC returned an invalid Secure Boot resource path\n' "${index}" >&2
        return 1
    }
}

read_secure_boot_states() {
    local index="$1" require_reset="${2:-false}" state_line
    prepare_worker_context "${index}" || return 1
    resolve_worker_resources "${index}" "${require_reset}" || return 1
    redfish_request GET "${BASE_URL}${SECURE_BOOT_PATH}" "${RESPONSE_FILE}" || {
        printf 'ERROR: Could not read worker %s Secure Boot resource\n' "${index}" >&2
        return 1
    }
    state_line="$(jq -r '
        def secure_boot_state:
            if . == true then "enabled"
            elif . == false then "disabled"
            elif type == "string" then
                if ascii_downcase == "enabled" then "enabled"
                elif ascii_downcase == "disabled" then "disabled"
                else "unknown"
                end
            else "unknown"
            end;
        [(.SecureBootEnable | secure_boot_state),
         (.SecureBootCurrentBoot | secure_boot_state),
         (.SecureBootMode // "unknown")] | @tsv
    ' "${RESPONSE_FILE}")" || return 1
    IFS=$'\t' read -r CONFIGURED_STATE CURRENT_BOOT_STATE SECURE_BOOT_MODE <<< "${state_line}"
}

read_current_boot_state() {
    read_secure_boot_states "$1" false || return 1
    printf '%s' "${CURRENT_BOOT_STATE}"
}

precheck_worker_secure_boot() {
    local index="$1" desired="$2" desired_state
    desired_state="$(desired_boot_state "${desired}")"
    read_secure_boot_states "${index}" true || {
        printf 'ERROR: Secure Boot precheck failed for worker %s\n' "${index}" >&2
        return 1
    }

    if [[ "${CONFIGURED_STATE}" == "${desired_state}" && "${CURRENT_BOOT_STATE}" == "${desired_state}" ]]; then
        # PRECHECK_OPERATION is the machine-readable result; status messages go to stderr.
        PRECHECK_OPERATION=ready
        printf 'Worker %s already has Secure Boot %s for its current boot; skipping change and reboot\n' \
            "${index}" "${desired}" >&2
    elif [[ "${CONFIGURED_STATE}" == "${desired_state}" ]]; then
        PRECHECK_OPERATION=reboot
        printf 'Worker %s is configured for Secure Boot %s but current boot is %s; skipping PATCH\n' \
            "${index}" "${desired}" "${CURRENT_BOOT_STATE}" >&2
    else
        PRECHECK_OPERATION=set
        printf 'Worker %s Secure Boot is configured as %s (current boot %s); will set %s\n' \
            "${index}" "${CONFIGURED_STATE}" "${CURRENT_BOOT_STATE}" "${desired}" >&2
    fi
}

apply_worker_secure_boot() {
    local index="$1" desired="$2" operation="$3" system_path="$4"
    local secure_boot_path="$5" reset_target="$6" desired_json reset_url
    [[ "${operation}" != ready ]] || return 0

    prepare_worker_context "${index}" || return 1
    SYSTEM_PATH="${system_path}"
    SECURE_BOOT_PATH="${secure_boot_path}"
    RESET_TARGET="${reset_target}"

    if [[ "${operation}" == set ]]; then
        if [[ "${desired}" == enable ]]; then
            desired_json='{"SecureBootEnable":true}'
        else
            desired_json='{"SecureBootEnable":false}'
        fi
        redfish_request PATCH "${BASE_URL}${SECURE_BOOT_PATH}" "${RESPONSE_FILE}" "${desired_json}" || {
            printf 'ERROR: BMC rejected the Secure Boot change for worker %s\n' "${index}" >&2
            return 1
        }
        printf 'Secure Boot %s setting accepted for worker %s (%s)\n' "${desired}" "${index}" "${BMC_IP}"
    fi

    reset_url="${BASE_URL}${RESET_TARGET}"
    redfish_request POST "${reset_url}" "${RESPONSE_FILE}" "{\"ResetType\":\"${RESET_TYPE}\"}" || {
        printf 'ERROR: BMC rejected the reboot request for worker %s\n' "${index}" >&2
        return 1
    }
    printf '%s requested for worker %s (%s)\n' "${RESET_TYPE}" "${index}" "${BMC_IP}"
}

set_worker_secure_boot() {
    local index="$1" desired="$2"
    precheck_worker_secure_boot "${index}" "${desired}" || return 1
    apply_worker_secure_boot "${index}" "${desired}" "${PRECHECK_OPERATION}" \
        "${SYSTEM_PATH}" "${SECURE_BOOT_PATH}" "${RESET_TARGET}"
}

validate_timeout() {
    local timeout_minutes="$1"
    [[ "${timeout_minutes}" =~ ^[1-9][0-9]*$ ]] || die "Timeout must be a positive number of minutes"
}

wait_for_all_workers() {
    local desired="$1" timeout_minutes="$2" index current_state remaining all_ready desired_state
    local REDFISH_REQUEST_DEADLINE=$((SECONDS + timeout_minutes * 60))
    local deadline="${REDFISH_REQUEST_DEADLINE}" round_start elapsed sleep_for
    local -a worker_indices=("${@:3}")
    desired_state="$(desired_boot_state "${desired}")"

    while :; do
        round_start="${SECONDS}"
        all_ready=true
        for index in "${worker_indices[@]}"; do
            current_state="$(read_current_boot_state "${index}" 2>/dev/null || true)"
            if [[ "${current_state}" == "${desired_state}" ]]; then
                printf 'Worker %s ready: SecureBootCurrentBoot=%s\n' "${index}" "${current_state}"
            else
                all_ready=false
                printf 'Worker %s pending (SecureBootCurrentBoot=%s)\n' \
                    "${index}" "${current_state:-unreachable}"
            fi
        done
        [[ "${all_ready}" == true ]] && return 0

        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        elapsed=$((SECONDS - round_start))
        sleep_for=$((POLL_INTERVAL_SECONDS - elapsed))
        (( sleep_for > remaining )) && sleep_for="${remaining}"
        (( sleep_for > 0 )) && sleep "${sleep_for}"
    done
    if (( ${#worker_indices[@]} == 1 )); then
        printf 'ERROR: Worker %s did not reach SecureBootCurrentBoot=%s within %s minutes\n' \
            "${worker_indices[0]}" "${desired_state}" "${timeout_minutes}" >&2
    else
        printf 'ERROR: Not all workers reached SecureBootCurrentBoot=%s within %s minutes\n' \
            "${desired_state}" "${timeout_minutes}" >&2
    fi
    return 1
}

show_worker_secure_boot() {
    local index="$1"
    read_secure_boot_states "${index}" false || return 1
    printf 'Worker %s (%s): SecureBootEnable=%s\n' "${index}" "${BMC_IP}" "${CONFIGURED_STATE}"
    printf 'SecureBootCurrentBoot=%s, SecureBootMode=%s\n' "${CURRENT_BOOT_STATE}" "${SECURE_BOOT_MODE}"
}

main() {
    local action="${1:-}" index="${2:-}" desired="${3:-}" timeout_minutes="${4:-15}"
    local worker_count worker_index worker_position operation
    local -a worker_indices=() worker_operations=() worker_system_paths=()
    local -a worker_secure_boot_paths=() worker_reset_targets=()

    load_worker_env
    case "${action}" in
        show)
            [[ $# -eq 2 ]] && is_worker_index "${index}" || { usage >&2; exit 2; }
            show_worker_secure_boot "${index}" || exit 1
            ;;
        set)
            [[ $# -eq 3 ]] && is_worker_index "${index}" && is_desired_state "${desired}" || {
                usage >&2
                exit 2
            }
            set_worker_secure_boot "${index}" "${desired}" || exit 1
            ;;
        wait)
            [[ ( $# -eq 3 || $# -eq 4 ) ]] && is_worker_index "${index}" && \
                is_desired_state "${desired}" || {
                usage >&2
                exit 2
            }
            validate_timeout "${timeout_minutes}"
            wait_for_all_workers "${desired}" "${timeout_minutes}" "${index}"
            ;;
        all)
            [[ ( $# -eq 2 || $# -eq 3 ) ]] && is_desired_state "${index}" || {
                usage >&2
                exit 2
            }
            desired="${index}"
            timeout_minutes="${3:-15}"
            validate_timeout "${timeout_minutes}"
            worker_count="${WORKER_COUNT:-}"
            [[ "${worker_count}" =~ ^[0-9]+$ ]] || die "WORKER_COUNT must be set to a non-negative integer"
            (( worker_count > 0 )) || die "WORKER_COUNT is zero; there are no workers to update"
            for ((worker_index = 1; worker_index <= worker_count; worker_index++)); do
                worker_has_bmc_credentials "${worker_index}" || \
                    die "BMC settings are incomplete for worker ${worker_index}"
                worker_indices+=("${worker_index}")
            done
            printf 'Prechecking Secure Boot state for %s worker(s)\n' "${#worker_indices[@]}"
            for worker_index in "${worker_indices[@]}"; do
                precheck_worker_secure_boot "${worker_index}" "${desired}" || exit 1
                worker_operations+=("${PRECHECK_OPERATION}")
                worker_system_paths+=("${SYSTEM_PATH}")
                worker_secure_boot_paths+=("${SECURE_BOOT_PATH}")
                worker_reset_targets+=("${RESET_TARGET}")
            done
            for worker_position in "${!worker_indices[@]}"; do
                worker_index="${worker_indices[worker_position]}"
                operation="${worker_operations[worker_position]}"
                apply_worker_secure_boot "${worker_index}" "${desired}" "${operation}" \
                    "${worker_system_paths[worker_position]}" \
                    "${worker_secure_boot_paths[worker_position]}" \
                    "${worker_reset_targets[worker_position]}" || exit 1
            done
            wait_for_all_workers "${desired}" "${timeout_minutes}" "${worker_indices[@]}"
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
