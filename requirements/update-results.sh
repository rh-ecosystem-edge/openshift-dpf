#!/usr/bin/env bash
#
# update-results.sh — Run tests for each requirement and post results to GitHub Issues.
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
#   RUN_URL            — optional link to a CI run or context for the comment

set -euo pipefail

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
    GITHUB_REPOSITORY=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    if [[ -z "${GITHUB_REPOSITORY}" ]]; then
        echo "ERROR: GITHUB_REPOSITORY is not set and could not be detected." >&2
        exit 1
    fi
fi

REPO_FLAG="-R ${GITHUB_REPOSITORY}"
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
RUN_URL="${RUN_URL:-}"

REQ_COUNT=$(jq '.requirements | length' "${REQUIREMENTS_FILE}")
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

echo "=== Running tests and posting results ==="
echo "Repository : ${GITHUB_REPOSITORY}"
echo "Requirements: ${REQ_COUNT}"
echo ""

for i in $(seq 0 $((REQ_COUNT - 1))); do
    REQ_ID=$(jq -r ".requirements[${i}].id" "${REQUIREMENTS_FILE}")
    REQ_TEXT=$(jq -r ".requirements[${i}].requirement" "${REQUIREMENTS_FILE}")
    TEST_IMPL=$(jq -r ".requirements[${i}].test_implementation" "${REQUIREMENTS_FILE}")
    ISSUE_NUM=$(jq -r ".requirements[${i}].issue_number" "${REQUIREMENTS_FILE}")

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

    if [[ "${ISSUE_NUM}" == "null" || -z "${ISSUE_NUM}" ]]; then
        echo "  [${REQ_ID}] No issue number — run sync-issues.sh first."
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

    OUTPUT_LINES=$(tail -50 "${OUTPUT_FILE}")
    rm -f "${OUTPUT_FILE}"

    echo "    -> ${STATUS_ICON} (exit code ${EXIT_CODE})"

    COMMENT_BODY="## Test Result: ${STATUS_ICON}

| Field | Value |
|-------|-------|
| **Requirement** | ${REQ_ID} |
| **Command** | \`${TEST_IMPL}\` |
| **Exit Code** | ${EXIT_CODE} |
| **Result** | **${RESULT}** |
| **Timestamp** | ${TIMESTAMP} |"

    if [[ -n "${RUN_URL}" ]]; then
        COMMENT_BODY="${COMMENT_BODY}
| **Run** | [View](${RUN_URL}) |"
    fi

    if [[ -n "${OUTPUT_LINES}" ]]; then
        COMMENT_BODY="${COMMENT_BODY}

<details>
<summary>Output (last 50 lines)</summary>

\`\`\`
${OUTPUT_LINES}
\`\`\`

</details>"
    fi

    if [[ "${DRY_RUN}" == "false" ]]; then
        gh issue comment "${ISSUE_NUM}" ${REPO_FLAG} --body "${COMMENT_BODY}"

        if [[ "${RESULT}" == "pass" ]]; then
            ADD_LABEL="status/passing"
            REMOVE_LABELS="status/failing,status/untested"
        else
            ADD_LABEL="status/failing"
            REMOVE_LABELS="status/passing,status/untested"
        fi
        gh issue edit "${ISSUE_NUM}" ${REPO_FLAG} --add-label "${ADD_LABEL}" --remove-label "${REMOVE_LABELS}" 2>/dev/null || true
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
