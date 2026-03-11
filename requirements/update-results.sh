#!/usr/bin/env bash
#
# update-results.sh — Run tests for each requirement and update status labels on GitHub Issues.
#
# Finds issues by their REQ-XXX label (no issue numbers stored in JSON).
#
# Usage:
#   ./requirements/update-results.sh [--dry-run] [REQ-001 REQ-002 ...]
#
# If requirement IDs are given as arguments, only those are tested.
# Otherwise all requirements with a test_implementation are tested.
#
# Each requirement's test_implementation is a command that exits 0 for pass
# or non-zero for fail. Commands are run from the repo root.
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - jq installed
#   - GITHUB_REPOSITORY set (auto-set in GitHub Actions, or export manually)
#
# Optional env vars:
#   REQUIREMENTS_FILE  — path to requirements JSON (default: requirements/requirements.json)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${REPO_ROOT}/requirements/requirements.json}"

DRY_RUN=false
FILTER_IDS=()
for arg in "$@"; do
    if [[ "${arg}" == "--dry-run" ]]; then
        DRY_RUN=true
    else
        FILTER_IDS+=("${arg}")
    fi
done

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] Results will not be posted to GitHub."
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    GITHUB_REPOSITORY=$(jq -r '.repo // empty' "${REQUIREMENTS_FILE}" 2>/dev/null || true)
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    echo "ERROR: GITHUB_REPOSITORY is not set and 'repo' is not defined in ${REQUIREMENTS_FILE}." >&2
    exit 1
fi

REPO_FLAG="-R ${GITHUB_REPOSITORY}"
PROJECT_NAME=$(jq -r '.project' "${REQUIREMENTS_FILE}")

# ── Build label -> issue number map ──────────────────────────────────
echo "=== Fetching issue mapping ==="
declare -A ISSUE_MAP
ISSUE_LIST=$(gh issue list ${REPO_FLAG} --state all --limit 500 --json number,labels \
    --jq '.[] | "\(.number)|\([.labels[].name] | join(","))"' 2>/dev/null || true)

while IFS='|' read -r num labels; do
    [[ -z "${num}" ]] && continue
    for label in $(echo "${labels}" | tr ',' '\n'); do
        if [[ "${label}" =~ ^REQ-[0-9]+$ ]]; then
            ISSUE_MAP["${label}"]="${num}"
        fi
    done
done <<< "${ISSUE_LIST}"

echo "  Mapped ${#ISSUE_MAP[@]} requirement issues."
echo ""

# ── Resolve project and status field metadata ────────────────────────
OWNER=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f1)
PROJECT_NUM=""
PROJECT_ID=""
STATUS_FIELD_ID=""
declare -A STATUS_OPTION_IDS
ITEM_JSON=""

if [[ -n "${PROJECT_NAME}" && "${PROJECT_NAME}" != "null" ]]; then
    echo "=== Resolving project ==="
    PROJECT_LIST=$(gh project list --owner "${OWNER}" --format json 2>/dev/null || echo '{"projects":[]}')
    PROJECT_NUM=$(echo "${PROJECT_LIST}" | jq -r ".projects[] | select(.title == \"${PROJECT_NAME}\") | .number" 2>/dev/null || true)

    if [[ -z "${PROJECT_NUM}" ]]; then
        OWNER="@me"
        PROJECT_LIST=$(gh project list --owner "@me" --format json 2>/dev/null || echo '{"projects":[]}')
        PROJECT_NUM=$(echo "${PROJECT_LIST}" | jq -r ".projects[] | select(.title == \"${PROJECT_NAME}\") | .number" 2>/dev/null || true)
    fi

    if [[ -n "${PROJECT_NUM}" ]]; then
        PROJECT_ID=$(echo "${PROJECT_LIST}" | jq -r ".projects[] | select(.title == \"${PROJECT_NAME}\") | .id" 2>/dev/null || true)

        FIELD_JSON=$(gh project field-list "${PROJECT_NUM}" --owner "${OWNER}" --format json 2>/dev/null || echo '{"fields":[]}')
        STATUS_FIELD_ID=$(echo "${FIELD_JSON}" | jq -r '.fields[] | select(.name == "Requirement Status") | .id' 2>/dev/null || true)

        if [[ -n "${STATUS_FIELD_ID}" ]]; then
            for opt_name in Untested Passing Failing; do
                opt_id=$(echo "${FIELD_JSON}" | jq -r ".fields[] | select(.name == \"Requirement Status\") | .options[] | select(.name == \"${opt_name}\") | .id" 2>/dev/null || true)
                if [[ -n "${opt_id}" ]]; then
                    STATUS_OPTION_IDS["${opt_name}"]="${opt_id}"
                fi
            done
            ITEM_JSON=$(gh project item-list "${PROJECT_NUM}" --owner "${OWNER}" --format json --limit 500 2>/dev/null || echo '{"items":[]}')
            echo "  Project #${PROJECT_NUM} with status field ready."
        else
            echo "  WARNING: 'Requirement Status' field not found on project — run sync-issues.sh first." >&2
        fi
    else
        echo "  WARNING: Project '${PROJECT_NAME}' not found — skipping project status updates." >&2
    fi
    echo ""
fi

REQ_COUNT=$(jq '.requirements | length' "${REQUIREMENTS_FILE}")
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

echo "=== Running tests ==="
echo "Repository : ${GITHUB_REPOSITORY}"
echo "Requirements: ${REQ_COUNT}"
echo ""

for i in $(seq 0 $((REQ_COUNT - 1))); do
    REQ_ID=$(jq -r ".requirements[${i}].id" "${REQUIREMENTS_FILE}")
    REQ_TEXT=$(jq -r ".requirements[${i}].requirement" "${REQUIREMENTS_FILE}")
    TEST_IMPL=$(jq -r ".requirements[${i}].test_implementation" "${REQUIREMENTS_FILE}")

    # If specific IDs were requested, skip others
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

    if [[ -z "${TEST_IMPL}" || "${TEST_IMPL}" == "null" ]]; then
        echo "  [${REQ_ID}] No test implementation — skipping."
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    ISSUE_NUM="${ISSUE_MAP[${REQ_ID}]:-}"
    if [[ -z "${ISSUE_NUM}" ]]; then
        echo "  [${REQ_ID}] No issue found — run sync-issues.sh first."
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    echo "  [${REQ_ID}] Running: ${TEST_IMPL}"

    OUTPUT_FILE=$(mktemp)
    set +e
    (cd "${REPO_ROOT}" && eval "${TEST_IMPL}") > "${OUTPUT_FILE}" 2>&1
    EXIT_CODE=$?
    set -e

    if [[ ${EXIT_CODE} -eq 0 ]]; then
        RESULT="pass"
        STATUS_ICON="PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        RESULT="fail"
        STATUS_ICON="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    rm -f "${OUTPUT_FILE}"

    echo "    -> ${STATUS_ICON} (exit code ${EXIT_CODE})"

    if [[ "${DRY_RUN}" == "false" ]]; then
        if [[ "${RESULT}" == "pass" ]]; then
            ADD_LABEL="status/passing"
            REMOVE_LABELS="status/failing,status/untested"
            STATUS_NAME="Passing"
        else
            ADD_LABEL="status/failing"
            REMOVE_LABELS="status/passing,status/untested"
            STATUS_NAME="Failing"
        fi
        gh issue edit "${ISSUE_NUM}" ${REPO_FLAG} --add-label "${ADD_LABEL}" --remove-label "${REMOVE_LABELS}" 2>/dev/null || true

        if [[ -n "${STATUS_FIELD_ID}" && -n "${PROJECT_ID}" ]]; then
            OPTION_ID="${STATUS_OPTION_IDS[${STATUS_NAME}]:-}"
            ITEM_ID=$(echo "${ITEM_JSON}" | jq -r ".items[] | select(.content.number == ${ISSUE_NUM} and .content.type == \"Issue\") | .id" 2>/dev/null || true)
            if [[ -n "${OPTION_ID}" && -n "${ITEM_ID}" ]]; then
                gh project item-edit \
                    --id "${ITEM_ID}" \
                    --project-id "${PROJECT_ID}" \
                    --field-id "${STATUS_FIELD_ID}" \
                    --single-select-option-id "${OPTION_ID}" 2>/dev/null || echo "    -> WARNING: failed to update project status" >&2
            fi
        fi
    fi
done

echo ""
echo "=== Summary ==="
echo "  Passed : ${PASS_COUNT}"
echo "  Failed : ${FAIL_COUNT}"
echo "  Skipped: ${SKIP_COUNT}"
echo "=== Done ==="

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
fi
