#!/usr/bin/env bash
#
# sync-issues.sh — Sync requirements.json to GitHub Issues and a GitHub Project.
#
# Idempotent: each requirement gets a label matching its ID (e.g. REQ-001).
# The script searches by label to find existing issues, so re-runs never
# produce duplicates. No issue numbers are stored in the JSON.
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

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${REPO_ROOT}/requirements/requirements.json}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[dry-run] No changes will be made."
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    GITHUB_REPOSITORY=$(jq -r '.repo // empty' "${REQUIREMENTS_FILE}" 2>/dev/null || true)
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    echo "ERROR: GITHUB_REPOSITORY is not set and 'repo' is not defined in ${REQUIREMENTS_FILE}." >&2
    exit 1
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

REQ_IDS=$(jq -r '.requirements[].id' "${REQUIREMENTS_FILE}" | sort -u)
for req_id in ${REQ_IDS}; do
    echo "  Label: ${req_id}"
    if [[ "${DRY_RUN}" == "false" ]]; then
        gh label create "${req_id}" ${REPO_FLAG} --color "1d76db" --force 2>/dev/null || true
    fi
done
echo ""

# ── Fetch existing issues by label to avoid duplicates ───────────────
echo "=== Fetching existing issues ==="
declare -A EXISTING_ISSUES
declare -A EXISTING_TITLES
ISSUE_LIST=$(gh issue list ${REPO_FLAG} --state all --limit 500 --json number,labels,title \
    --jq '.[] | "\(.number)|\([.labels[].name] | join(","))|\(.title)"' 2>/dev/null || true)

while IFS='|' read -r num labels title; do
    [[ -z "${num}" ]] && continue
    EXISTING_TITLES["${title}"]="${num}"
    for label in $(echo "${labels}" | tr ',' '\n'); do
        if [[ "${label}" =~ ^REQ-[0-9]+$ ]]; then
            EXISTING_ISSUES["${label}"]="${num}"
        fi
    done
done <<< "${ISSUE_LIST}"

echo "  Found ${#EXISTING_ISSUES[@]} existing requirement issues."
echo ""

# ── Create or update issues ──────────────────────────────────────────
echo "=== Syncing issues ==="
declare -A SYNCED_ISSUES

for i in $(seq 0 $((REQ_COUNT - 1))); do
    REQ_ID=$(jq -r ".requirements[${i}].id" "${REQUIREMENTS_FILE}")
    REQ_TEXT=$(jq -r ".requirements[${i}].requirement" "${REQUIREMENTS_FILE}")
    REQ_DESC=$(jq -r ".requirements[${i}].description // empty" "${REQUIREMENTS_FILE}")
    TEST_DESC=$(jq -r ".requirements[${i}].test_description" "${REQUIREMENTS_FILE}")
    TEST_IMPL=$(jq -r ".requirements[${i}].test_implementation" "${REQUIREMENTS_FILE}")
    REQ_LABELS=$(jq -r ".requirements[${i}].labels | join(\",\")" "${REQUIREMENTS_FILE}")

    TITLE="[${REQ_ID}] ${REQ_TEXT}"
    ALL_LABELS="${REQ_LABELS},${REQ_ID}"

    DESC_SECTION=""
    if [[ -n "${REQ_DESC}" ]]; then
        DESC_SECTION="
## Description

${REQ_DESC}
"
    fi

    BODY="## Requirement

${REQ_TEXT}
${DESC_SECTION}
## Test Description

${TEST_DESC}

## Test Implementation

\`${TEST_IMPL:-not yet implemented}\`

---
_Managed by [requirements/requirements.json](../requirements/requirements.json) — do not edit manually._
_Requirement ID: ${REQ_ID}_"

    ISSUE_NUM="${EXISTING_ISSUES[${REQ_ID}]:-}"

    if [[ -n "${ISSUE_NUM}" ]]; then
        echo "  [${REQ_ID}] Updating issue #${ISSUE_NUM}"
        if [[ "${DRY_RUN}" == "false" ]]; then
            gh issue edit "${ISSUE_NUM}" ${REPO_FLAG} \
                --title "${TITLE}" \
                --body "${BODY}" \
                --add-label "${ALL_LABELS}" 2>&1 || echo "    -> WARNING: failed to update issue #${ISSUE_NUM}" >&2
        else
            echo "    -> [dry-run] Would update issue #${ISSUE_NUM}"
        fi
        SYNCED_ISSUES["${REQ_ID}"]="${ISSUE_NUM}"
    else
        echo "  [${REQ_ID}] Creating issue: ${TITLE}"
        if [[ "${DRY_RUN}" == "false" ]]; then
            CREATE_OUTPUT=$(gh issue create ${REPO_FLAG} \
                --title "${TITLE}" \
                --body "${BODY}" \
                --label "${ALL_LABELS},status/untested" 2>&1) || {
                echo "    -> ERROR creating issue: ${CREATE_OUTPUT}" >&2
                continue
            }
            NEW_NUM=$(echo "${CREATE_OUTPUT}" | grep -oE '[0-9]+$' || true)
            if [[ -z "${NEW_NUM}" ]]; then
                echo "    -> ERROR: could not extract issue number from: ${CREATE_OUTPUT}" >&2
                continue
            fi
            echo "    -> Created issue #${NEW_NUM}"
            SYNCED_ISSUES["${REQ_ID}"]="${NEW_NUM}"
        else
            echo "    -> [dry-run] Would create issue"
        fi
    fi
done
echo ""

# ── Create sub-issues ────────────────────────────────────────────────
echo "=== Syncing sub-issues ==="

for i in $(seq 0 $((REQ_COUNT - 1))); do
    REQ_ID=$(jq -r ".requirements[${i}].id" "${REQUIREMENTS_FILE}")
    SUB_COUNT=$(jq ".requirements[${i}].subtasks | length" "${REQUIREMENTS_FILE}")
    PARENT_NUM="${SYNCED_ISSUES[${REQ_ID}]:-}"

    [[ "${SUB_COUNT}" -eq 0 ]] && continue
    [[ -z "${PARENT_NUM}" ]] && continue

    echo "  [${REQ_ID}] Processing ${SUB_COUNT} subtask(s) for issue #${PARENT_NUM}"

    for j in $(seq 0 $((SUB_COUNT - 1))); do
        SUB_TITLE_RAW=$(jq -r ".requirements[${i}].subtasks[${j}].title" "${REQUIREMENTS_FILE}")
        SUB_DESC=$(jq -r ".requirements[${i}].subtasks[${j}].description // empty" "${REQUIREMENTS_FILE}")
        SUB_TITLE="[${REQ_ID}] ${SUB_TITLE_RAW}"

        CHILD_NUM="${EXISTING_TITLES[${SUB_TITLE}]:-}"

        if [[ -n "${CHILD_NUM}" ]]; then
            echo "    Subtask already exists: #${CHILD_NUM} — ${SUB_TITLE}"
            if [[ "${DRY_RUN}" == "false" ]]; then
                gh issue edit "${CHILD_NUM}" ${REPO_FLAG} \
                    --title "${SUB_TITLE}" \
                    --body "${SUB_DESC}" \
                    --add-label "${REQ_ID}" 2>&1 || echo "      -> WARNING: failed to update subtask #${CHILD_NUM}" >&2
            fi
        else
            echo "    Creating subtask: ${SUB_TITLE}"
            if [[ "${DRY_RUN}" == "false" ]]; then
                SUB_OUTPUT=$(gh issue create ${REPO_FLAG} \
                    --title "${SUB_TITLE}" \
                    --body "${SUB_DESC}" \
                    --label "${REQ_ID}" 2>&1) || {
                    echo "      -> ERROR creating subtask: ${SUB_OUTPUT}" >&2
                    continue
                }
                CHILD_NUM=$(echo "${SUB_OUTPUT}" | grep -oE '[0-9]+$' || true)
                if [[ -z "${CHILD_NUM}" ]]; then
                    echo "      -> ERROR: could not extract issue number from: ${SUB_OUTPUT}" >&2
                    continue
                fi
                echo "      -> Created subtask #${CHILD_NUM}"
            else
                echo "      -> [dry-run] Would create subtask"
                continue
            fi
        fi

        if [[ "${DRY_RUN}" == "false" && -n "${CHILD_NUM}" ]]; then
            echo "    Linking #${CHILD_NUM} as sub-issue of #${PARENT_NUM}"
            PARENT_ID=$(gh issue view "${PARENT_NUM}" ${REPO_FLAG} --json id --jq ".id" 2>/dev/null || true)
            CHILD_ID=$(gh issue view "${CHILD_NUM}" ${REPO_FLAG} --json id --jq ".id" 2>/dev/null || true)
            if [[ -n "${PARENT_ID}" && -n "${CHILD_ID}" ]]; then
                gh api graphql \
                    -H "GraphQL-Features: sub_issues" \
                    -f query="mutation { addSubIssue(input: { issueId: \"${PARENT_ID}\", subIssueId: \"${CHILD_ID}\" }) { issue { title } subIssue { title } } }" 2>/dev/null || echo "      -> WARNING: failed to link sub-issue" >&2
            else
                echo "      -> WARNING: could not resolve issue IDs for linking" >&2
            fi
        else
            echo "      -> [dry-run] Would link subtask as sub-issue of #${PARENT_NUM}"
        fi
    done
done
echo ""

# ── GitHub Project ───────────────────────────────────────────────────
echo "=== Syncing GitHub Project ==="

OWNER=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f1)

PROJECT_LIST=$(gh project list --owner "${OWNER}" --format json 2>/dev/null || echo '{"projects":[]}')
PROJECT_NUM=$(echo "${PROJECT_LIST}" | jq -r ".projects[] | select(.title == \"${PROJECT_NAME}\") | .number" 2>/dev/null || true)

if [[ -z "${PROJECT_NUM}" ]]; then
    echo "  Project not found under owner '${OWNER}', trying @me..."
    OWNER="@me"
    PROJECT_LIST=$(gh project list --owner "@me" --format json 2>/dev/null || echo '{"projects":[]}')
    PROJECT_NUM=$(echo "${PROJECT_LIST}" | jq -r ".projects[] | select(.title == \"${PROJECT_NAME}\") | .number" 2>/dev/null || true)
fi

if [[ -z "${PROJECT_NUM}" ]]; then
    echo "  WARNING: Project '${PROJECT_NAME}' not found. Create it manually, then re-run." >&2
else
    echo "  Found project: #${PROJECT_NUM}"
    PROJECT_ID=$(echo "${PROJECT_LIST}" | jq -r ".projects[] | select(.title == \"${PROJECT_NAME}\") | .id" 2>/dev/null || true)

    if [[ "${DRY_RUN}" == "false" ]]; then
        for REQ_ID in "${!SYNCED_ISSUES[@]}"; do
            ISSUE_NUM="${SYNCED_ISSUES[${REQ_ID}]}"
            ISSUE_URL="https://github.com/${GITHUB_REPOSITORY}/issues/${ISSUE_NUM}"
            echo "  Adding issue #${ISSUE_NUM} (${REQ_ID}) to project #${PROJECT_NUM}"
            gh project item-add "${PROJECT_NUM}" --owner "${OWNER}" --url "${ISSUE_URL}" 2>/dev/null || true
        done
    else
        echo "    -> [dry-run] Would add ${#SYNCED_ISSUES[@]} issues to project #${PROJECT_NUM}"
    fi

    # ── Ensure "Requirement Status" field exists on the project ──────
    echo ""
    echo "=== Syncing Project Status Field ==="

    FIELD_JSON=$(gh project field-list "${PROJECT_NUM}" --owner "${OWNER}" --format json 2>/dev/null || echo '{"fields":[]}')
    STATUS_FIELD_ID=$(echo "${FIELD_JSON}" | jq -r '.fields[] | select(.name == "Requirement Status") | .id' 2>/dev/null || true)

    if [[ -z "${STATUS_FIELD_ID}" ]]; then
        echo "  Creating 'Requirement Status' single-select field..."
        if [[ "${DRY_RUN}" == "false" ]]; then
            gh project field-create "${PROJECT_NUM}" --owner "${OWNER}" \
                --name "Requirement Status" --data-type "SINGLE_SELECT" \
                --single-select-options "Untested,Passing,Failing" 2>/dev/null || echo "  -> WARNING: failed to create field" >&2
        else
            echo "    -> [dry-run] Would create 'Requirement Status' field"
        fi
    else
        echo "  Found 'Requirement Status' field: ${STATUS_FIELD_ID}"
    fi
fi

echo ""
echo "=== Done ==="
