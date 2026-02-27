#!/usr/bin/env bash
#
# sync-issues.sh — Sync requirements.json to GitHub Issues and a GitHub Project.
#
# Usage:
#   ./requirements/sync-issues.sh [--dry-run]
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - jq installed
#   - GITHUB_REPOSITORY set (auto-set in GitHub Actions, or export manually e.g. "rh-ecosystem-edge/openshift-dpf")
#
# Optional env vars:
#   REQUIREMENTS_FILE  — path to requirements JSON (default: requirements/requirements.json)
#   PROJECT_TOKEN      — GitHub token with project scope (falls back to GH_TOKEN / GITHUB_TOKEN)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${REPO_ROOT}/requirements/requirements.json}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[dry-run] No changes will be made."
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    GITHUB_REPOSITORY=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    if [[ -z "${GITHUB_REPOSITORY}" ]]; then
        echo "ERROR: GITHUB_REPOSITORY is not set and could not be detected." >&2
        exit 1
    fi
fi

echo "Repository : ${GITHUB_REPOSITORY}"
echo "Requirements: ${REQUIREMENTS_FILE}"
echo ""

REPO_FLAG="-R ${GITHUB_REPOSITORY}"
PROJECT_NAME=$(jq -r '.project' "${REQUIREMENTS_FILE}")
REQ_COUNT=$(jq '.requirements | length' "${REQUIREMENTS_FILE}")
echo "Project    : ${PROJECT_NAME}"
echo "Requirements: ${REQ_COUNT}"
echo ""

# ── Ensure labels exist ──────────────────────────────────────────────
echo "=== Ensuring labels exist ==="
LABELS=$(jq -r '[.requirements[].labels[]] | unique | .[]' "${REQUIREMENTS_FILE}")
for label in ${LABELS}; do
    echo "  Label: ${label}"
    if [[ "${DRY_RUN}" == "false" ]]; then
        gh label create "${label}" ${REPO_FLAG} --force 2>/dev/null || true
    fi
done

STATUS_LABELS=("status/untested:cccccc" "status/passing:0e8a16" "status/failing:d93f0b")
for entry in "${STATUS_LABELS[@]}"; do
    label="${entry%%:*}"
    color="${entry##*:}"
    echo "  Label: ${label} (#${color})"
    if [[ "${DRY_RUN}" == "false" ]]; then
        gh label create "${label}" ${REPO_FLAG} --color "${color}" --force 2>/dev/null || true
    fi
done
echo ""

# ── Create or update issues ──────────────────────────────────────────
echo "=== Syncing issues ==="
UPDATED_JSON=$(cat "${REQUIREMENTS_FILE}")

for i in $(seq 0 $((REQ_COUNT - 1))); do
    REQ_ID=$(jq -r ".requirements[${i}].id" "${REQUIREMENTS_FILE}")
    REQ_TEXT=$(jq -r ".requirements[${i}].requirement" "${REQUIREMENTS_FILE}")
    TEST_DESC=$(jq -r ".requirements[${i}].test_description" "${REQUIREMENTS_FILE}")
    TEST_IMPL=$(jq -r ".requirements[${i}].test_implementation" "${REQUIREMENTS_FILE}")
    ISSUE_NUM=$(jq -r ".requirements[${i}].issue_number" "${REQUIREMENTS_FILE}")
    REQ_LABELS=$(jq -r ".requirements[${i}].labels | join(\",\")" "${REQUIREMENTS_FILE}")

    TITLE="[${REQ_ID}] ${REQ_TEXT}"

    BODY="## Requirement

${REQ_TEXT}

## Test Description

${TEST_DESC}

## Test Implementation

\`${TEST_IMPL:-not yet implemented}\`

---
_Managed by [requirements/requirements.json](../requirements/requirements.json) — do not edit manually._
_Requirement ID: ${REQ_ID}_"

    if [[ "${ISSUE_NUM}" == "null" || -z "${ISSUE_NUM}" ]]; then
        echo "  [${REQ_ID}] Creating issue: ${TITLE}"
        if [[ "${DRY_RUN}" == "false" ]]; then
            CREATE_OUTPUT=$(gh issue create ${REPO_FLAG} \
                --title "${TITLE}" \
                --body "${BODY}" \
                --label "${REQ_LABELS},status/untested" 2>&1) || {
                echo "    -> ERROR creating issue: ${CREATE_OUTPUT}" >&2
                continue
            }
            NEW_NUM=$(echo "${CREATE_OUTPUT}" | grep -oE '[0-9]+$' || true)
            if [[ -z "${NEW_NUM}" ]]; then
                echo "    -> ERROR: could not extract issue number from: ${CREATE_OUTPUT}" >&2
                continue
            fi
            echo "    -> Created issue #${NEW_NUM}"
            UPDATED_JSON=$(echo "${UPDATED_JSON}" | jq ".requirements[${i}].issue_number = ${NEW_NUM}")
        else
            echo "    -> [dry-run] Would create issue"
        fi
    else
        echo "  [${REQ_ID}] Updating issue #${ISSUE_NUM}: ${TITLE}"
        if [[ "${DRY_RUN}" == "false" ]]; then
            gh issue edit "${ISSUE_NUM}" ${REPO_FLAG} \
                --title "${TITLE}" \
                --body "${BODY}" \
                --add-label "${REQ_LABELS}" 2>&1 || echo "    -> WARNING: failed to update issue #${ISSUE_NUM}" >&2
        else
            echo "    -> [dry-run] Would update issue #${ISSUE_NUM}"
        fi
    fi
done
echo ""

# ── Write updated JSON back (with issue numbers) ────────────────────
if [[ "${DRY_RUN}" == "false" ]]; then
    echo "${UPDATED_JSON}" | jq '.' > "${REQUIREMENTS_FILE}"
    echo "Updated ${REQUIREMENTS_FILE} with issue numbers."
fi

# ── GitHub Project ───────────────────────────────────────────────────
echo ""
echo "=== Syncing GitHub Project ==="

OWNER=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f1)

PROJECT_LIST=$(gh project list --owner "${OWNER}" --format json 2>/dev/null || echo '{"projects":[]}')
PROJECT_NUM=$(echo "${PROJECT_LIST}" | jq -r ".projects[] | select(.title == \"${PROJECT_NAME}\") | .number" 2>/dev/null || true)

if [[ -z "${PROJECT_NUM}" ]]; then
    echo "  Creating project: ${PROJECT_NAME}"
    if [[ "${DRY_RUN}" == "false" ]]; then
        PROJECT_OUTPUT=$(gh project create --owner "${OWNER}" --title "${PROJECT_NAME}" --format json 2>&1) || {
            echo "    -> WARNING: failed to create project: ${PROJECT_OUTPUT}" >&2
            PROJECT_NUM=""
        }
        if [[ -n "${PROJECT_OUTPUT}" ]]; then
            PROJECT_NUM=$(echo "${PROJECT_OUTPUT}" | jq -r '.number' 2>/dev/null || true)
        fi
        echo "    -> Created project #${PROJECT_NUM}"
    else
        echo "    -> [dry-run] Would create project"
    fi
else
    echo "  Project already exists: #${PROJECT_NUM}"
fi

if [[ -n "${PROJECT_NUM}" && "${DRY_RUN}" == "false" ]]; then
    UPDATED_JSON=$(cat "${REQUIREMENTS_FILE}")
    for i in $(seq 0 $((REQ_COUNT - 1))); do
        ISSUE_NUM=$(echo "${UPDATED_JSON}" | jq -r ".requirements[${i}].issue_number")
        REQ_ID=$(echo "${UPDATED_JSON}" | jq -r ".requirements[${i}].id")
        if [[ "${ISSUE_NUM}" != "null" && -n "${ISSUE_NUM}" ]]; then
            ISSUE_URL="https://github.com/${GITHUB_REPOSITORY}/issues/${ISSUE_NUM}"
            echo "  Adding issue #${ISSUE_NUM} (${REQ_ID}) to project #${PROJECT_NUM}"
            gh project item-add "${PROJECT_NUM}" --owner "${OWNER}" --url "${ISSUE_URL}" 2>/dev/null || true
        fi
    done
fi

echo ""
echo "=== Done ==="
