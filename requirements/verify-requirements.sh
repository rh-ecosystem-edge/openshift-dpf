#!/usr/bin/env bash
#
# verify-requirements.sh — Run requirement tests locally and produce a report.
#
# Reads requirements.json, runs each requirement's test_implementation command,
# and outputs a summary report to stdout (and optionally to a file).
#
# Usage:
#   ./requirements/verify-requirements.sh [--output FILE] [--json] [REQ-001 REQ-002 ...]
#
# If requirement IDs are given as arguments, only those are tested.
# Otherwise all requirements with a test_implementation are tested.
#
# Each requirement's test_implementation is a command that exits 0 for pass
# or non-zero for fail. Commands are run from the repo root.
#
# Options:
#   --output FILE   Write the report to FILE in addition to stdout
#   --json          Output results as JSON (for CI consumption)
#
# Prerequisites:
#   - jq installed

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${REPO_ROOT}/requirements/requirements.json}"

OUTPUT_FILE=""
OUTPUT_JSON=false
FILTER_IDS=()
for arg in "$@"; do
    case "${arg}" in
        --output)  shift; OUTPUT_FILE="${1:-}" ;;
        --json)    OUTPUT_JSON=true ;;
        --output=*) OUTPUT_FILE="${arg#--output=}" ;;
        REQ-*)     FILTER_IDS+=("${arg}") ;;
    esac
    shift 2>/dev/null || true
done

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed." >&2
    exit 1
fi

if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
    echo "ERROR: requirements file not found: ${REQUIREMENTS_FILE}" >&2
    exit 1
fi

REQ_COUNT=$(jq '.requirements | length' "${REQUIREMENTS_FILE}")
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

declare -a RESULT_IDS=()
declare -a RESULT_TITLES=()
declare -a RESULT_STATUSES=()
declare -a RESULT_DETAILS=()
declare -a RESULT_LABELS=()

# ── Header ───────────────────────────────────────────────────────────
echo "================================================================================"
echo " Requirements Verification Report"
echo " ${TIMESTAMP}"
echo "================================================================================"
echo ""
echo "Requirements file: ${REQUIREMENTS_FILE}"
echo "Total requirements: ${REQ_COUNT}"
echo ""

# ── Run tests ────────────────────────────────────────────────────────
for i in $(seq 0 $((REQ_COUNT - 1))); do
    REQ_ID=$(jq -r ".requirements[${i}].id" "${REQUIREMENTS_FILE}")
    REQ_TEXT=$(jq -r ".requirements[${i}].requirement" "${REQUIREMENTS_FILE}")
    TEST_IMPL=$(jq -r ".requirements[${i}].test_implementation" "${REQUIREMENTS_FILE}")
    REQ_LABELS_STR=$(jq -r ".requirements[${i}].labels | join(\", \")" "${REQUIREMENTS_FILE}")

    # Filter if specific IDs were requested
    if [[ ${#FILTER_IDS[@]} -gt 0 ]]; then
        MATCHED=false
        for fid in "${FILTER_IDS[@]}"; do
            if [[ "${fid}" == "${REQ_ID}" ]]; then
                MATCHED=true
                break
            fi
        done
        if [[ "${MATCHED}" == "false" ]]; then
            continue
        fi
    fi

    RESULT_IDS+=("${REQ_ID}")
    RESULT_TITLES+=("${REQ_TEXT}")
    RESULT_LABELS+=("${REQ_LABELS_STR}")

    if [[ -z "${TEST_IMPL}" || "${TEST_IMPL}" == "null" ]]; then
        RESULT_STATUSES+=("SKIP")
        RESULT_DETAILS+=("No test implementation defined")
        SKIP_COUNT=$((SKIP_COUNT + 1))
        printf "  %-10s %-6s %s\n" "${REQ_ID}" "SKIP" "${REQ_TEXT}"
        continue
    fi

    OUTPUT_TMP=$(mktemp)
    set +e
    (cd "${REPO_ROOT}" && eval "${TEST_IMPL}") > "${OUTPUT_TMP}" 2>&1
    EXIT_CODE=$?
    set -e

    LAST_LINES=$(tail -5 "${OUTPUT_TMP}" | tr '\n' ' ')
    rm -f "${OUTPUT_TMP}"

    if [[ ${EXIT_CODE} -eq 0 ]]; then
        RESULT_STATUSES+=("PASS")
        RESULT_DETAILS+=("${LAST_LINES}")
        PASS_COUNT=$((PASS_COUNT + 1))
        printf "  %-10s \033[32m%-6s\033[0m %s\n" "${REQ_ID}" "PASS" "${REQ_TEXT}"
    else
        RESULT_STATUSES+=("FAIL")
        RESULT_DETAILS+=("Exit code ${EXIT_CODE}: ${LAST_LINES}")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf "  %-10s \033[31m%-6s\033[0m %s\n" "${REQ_ID}" "FAIL" "${REQ_TEXT}"
    fi
done

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "================================================================================"
echo " Summary"
echo "================================================================================"
printf "  Total : %d\n" "${TOTAL}"
printf "  \033[32mPass\033[0m  : %d\n" "${PASS_COUNT}"
printf "  \033[31mFail\033[0m  : %d\n" "${FAIL_COUNT}"
printf "  \033[33mSkip\033[0m  : %d\n" "${SKIP_COUNT}"
echo "================================================================================"

# ── JSON output ──────────────────────────────────────────────────────
if [[ "${OUTPUT_JSON}" == "true" ]]; then
    JSON_RESULTS="["
    for idx in "${!RESULT_IDS[@]}"; do
        [[ ${idx} -gt 0 ]] && JSON_RESULTS+=","
        # Escape strings for JSON
        DETAIL_ESC=$(echo "${RESULT_DETAILS[${idx}]}" | sed 's/"/\\"/g' | tr -d '\n')
        TITLE_ESC=$(echo "${RESULT_TITLES[${idx}]}" | sed 's/"/\\"/g')
        JSON_RESULTS+=$(cat <<ENTRY
{"id":"${RESULT_IDS[${idx}]}","requirement":"${TITLE_ESC}","status":"${RESULT_STATUSES[${idx}]}","detail":"${DETAIL_ESC}","labels":"${RESULT_LABELS[${idx}]}"}
ENTRY
)
    done
    JSON_RESULTS+="]"

    JSON_OUTPUT=$(cat <<JSONEOF
{
  "timestamp": "${TIMESTAMP}",
  "total": ${TOTAL},
  "pass": ${PASS_COUNT},
  "fail": ${FAIL_COUNT},
  "skip": ${SKIP_COUNT},
  "results": ${JSON_RESULTS}
}
JSONEOF
)
    echo ""
    echo "${JSON_OUTPUT}" | jq .
fi

# ── Write markdown report to file ───────────────────────────────────
if [[ -n "${OUTPUT_FILE}" ]]; then
    {
        echo "# Requirements Verification Report"
        echo ""
        echo "Generated: ${TIMESTAMP}"
        echo ""
        echo "| ID | Status | Requirement | Labels |"
        echo "|-----|--------|-------------|--------|"
        for idx in "${!RESULT_IDS[@]}"; do
            case "${RESULT_STATUSES[${idx}]}" in
                PASS) BADGE="PASS" ;;
                FAIL) BADGE="FAIL" ;;
                *)    BADGE="SKIP" ;;
            esac
            echo "| ${RESULT_IDS[${idx}]} | ${BADGE} | ${RESULT_TITLES[${idx}]} | ${RESULT_LABELS[${idx}]} |"
        done
        echo ""
        echo "## Summary"
        echo ""
        echo "- **Total**: ${TOTAL}"
        echo "- **Pass**: ${PASS_COUNT}"
        echo "- **Fail**: ${FAIL_COUNT}"
        echo "- **Skip**: ${SKIP_COUNT}"
    } > "${OUTPUT_FILE}"
    echo ""
    echo "Report written to: ${OUTPUT_FILE}"
fi

# Exit with failure if any tests failed
if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
fi
