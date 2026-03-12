#!/usr/bin/env bash
#
# status.sh — Show a quick summary of requirement status from GitHub issue labels.
#
# Finds issues by their REQ-XXX label (no issue numbers stored in JSON).
#
# Usage:
#   ./requirements/status.sh [--filter passing|failing|untested|no-issue] [--area AREA]
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - jq installed

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${REPO_ROOT}/requirements/requirements.json}"

FILTER_STATUS=""
FILTER_AREA=""
OUTPUT_CSV=false
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --filter) FILTER_STATUS="${2}"; shift 2 ;;
        --area)   FILTER_AREA="${2}"; shift 2 ;;
        --csv)    OUTPUT_CSV=true; shift ;;
        *)        echo "Unknown arg: ${1}" >&2; exit 1 ;;
    esac
done

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    GITHUB_REPOSITORY=$(jq -r '.repo // empty' "${REQUIREMENTS_FILE}" 2>/dev/null || true)
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    echo "ERROR: GITHUB_REPOSITORY is not set and 'repo' is not defined in ${REQUIREMENTS_FILE}." >&2
    exit 1
fi

REPO_FLAG="-R ${GITHUB_REPOSITORY}"
REQ_COUNT=$(jq '.requirements | length' "${REQUIREMENTS_FILE}")

PASS=0
FAIL=0
UNTESTED=0
NO_ISSUE=0

# ── Build REQ-XXX -> (issue_number, labels) map in one API call ──────
declare -A ISSUE_NUM_MAP
declare -A ISSUE_LABELS_MAP
ISSUE_LIST=$(gh issue list ${REPO_FLAG} --state all --limit 500 --json number,labels \
    --jq '.[] | "\(.number)|\([.labels[].name] | join(","))"' 2>/dev/null || true)

while IFS='|' read -r num labels; do
    [[ -z "${num}" ]] && continue
    for label in $(echo "${labels}" | tr ',' '\n'); do
        if [[ "${label}" =~ ^REQ-[0-9]+$ ]]; then
            ISSUE_NUM_MAP["${label}"]="${num}"
            ISSUE_LABELS_MAP["${label}"]="${labels}"
        fi
    done
done <<< "${ISSUE_LIST}"

REQ_COL=140
if [[ "${OUTPUT_CSV}" == "true" ]]; then
    echo "ID,ISSUE,LINK,REQUIREMENT,STATUS"
else
    printf "\n"
    printf "%-10s %-10s %-${REQ_COL}s %s\n" "ID" "ISSUE" "REQUIREMENT" "STATUS"
    printf "%-10s %-10s %-${REQ_COL}s %s\n" "----------" "----------" "$(printf '%0.s-' $(seq 1 ${REQ_COL}))" "--------"
fi

for i in $(seq 0 $((REQ_COUNT - 1))); do
    REQ_ID=$(jq -r ".requirements[${i}].id" "${REQUIREMENTS_FILE}")
    REQ_TEXT=$(jq -r ".requirements[${i}].requirement" "${REQUIREMENTS_FILE}")
    REQ_AREA=$(jq -r ".requirements[${i}].labels[] | select(startswith(\"area/\"))" "${REQUIREMENTS_FILE}" | head -1 | sed 's/area\///')

    if [[ -n "${FILTER_AREA}" && "${REQ_AREA}" != "${FILTER_AREA}" ]]; then
        continue
    fi

    ISSUE_NUM="${ISSUE_NUM_MAP[${REQ_ID}]:-}"
    LABELS="${ISSUE_LABELS_MAP[${REQ_ID}]:-}"

    if [[ -z "${ISSUE_NUM}" ]]; then
        STATUS="no-issue"
        NO_ISSUE=$((NO_ISSUE + 1))
    elif echo "${LABELS}" | grep -q "status/passing"; then
        STATUS="passing"
        PASS=$((PASS + 1))
    elif echo "${LABELS}" | grep -q "status/failing"; then
        STATUS="failing"
        FAIL=$((FAIL + 1))
    else
        STATUS="untested"
        UNTESTED=$((UNTESTED + 1))
    fi

    if [[ -n "${FILTER_STATUS}" && "${STATUS}" != "${FILTER_STATUS}" ]]; then
        continue
    fi

    case "${STATUS}" in
        passing)  STATUS_FMT="\033[32m${STATUS}\033[0m" ;;
        failing)  STATUS_FMT="\033[31m${STATUS}\033[0m" ;;
        untested) STATUS_FMT="\033[33m${STATUS}\033[0m" ;;
        *)        STATUS_FMT="\033[90m${STATUS}\033[0m" ;;
    esac

    if [[ -n "${ISSUE_NUM}" ]]; then
        ISSUE_FMT="#${ISSUE_NUM}"
    else
        ISSUE_FMT="-"
    fi

    if [[ "${OUTPUT_CSV}" == "true" ]]; then
        if [[ -n "${ISSUE_NUM}" ]]; then
            ISSUE_LINK="https://github.com/${GITHUB_REPOSITORY}/issues/${ISSUE_NUM}"
        else
            ISSUE_LINK=""
        fi
        CSV_REQ=$(echo "${REQ_TEXT}" | sed 's/"/""/g')
        echo "${REQ_ID},${ISSUE_FMT},${ISSUE_LINK},\"${CSV_REQ}\",${STATUS}"
    else
        if [[ ${#REQ_TEXT} -gt $((REQ_COL - 3)) ]]; then
            REQ_TEXT="${REQ_TEXT:0:$((REQ_COL - 3))}..."
        fi
        printf "%-10s %-10s %-${REQ_COL}s $(printf '%b' "${STATUS_FMT}")\n" "${REQ_ID}" "${ISSUE_FMT}" "${REQ_TEXT}"
    fi
done

if [[ "${OUTPUT_CSV}" != "true" ]]; then
    TOTAL=$((PASS + FAIL + UNTESTED + NO_ISSUE))
    printf "\n"
    printf "=== Summary ===\n"
    printf "  Total    : %d\n" "${TOTAL}"
    printf "  \033[32mPassing\033[0m  : %d\n" "${PASS}"
    printf "  \033[31mFailing\033[0m  : %d\n" "${FAIL}"
    printf "  \033[33mUntested\033[0m : %d\n" "${UNTESTED}"
    if [[ ${NO_ISSUE} -gt 0 ]]; then
        printf "  \033[90mNo issue\033[0m : %d\n" "${NO_ISSUE}"
    fi
    printf "\n"
fi
