# Requirements Tracking

This directory contains tooling to track project requirements as GitHub Issues, managed via a GitHub Project board.

## How It Works

1. **`requirements.json`** is the source of truth. Each requirement declares its description, test details, labels, and (once synced) the corresponding GitHub issue number.
2. **`sync-issues.sh`** reads the JSON and creates or updates GitHub Issues and a GitHub Project.
3. **`update-results.sh`** takes `go test -json` output and posts pass/fail results as comments on the corresponding issues.
4. **GitHub Actions** automate both steps — syncing on push and posting test results on a schedule.

## JSON Schema

Each entry in `requirements.json`:

| Field              | Type       | Description                                                  |
|--------------------|------------|--------------------------------------------------------------|
| `id`               | string     | Stable identifier, e.g. `REQ-001`. Never changes.           |
| `requirement`      | string     | Brief description of the requirement.                        |
| `test_description` | string     | What the test verifies / acceptance criteria.                |
| `test_implementation` | string  | Go test reference: `package/path::TestFunctionName`.         |
| `labels`           | string[]   | GitHub labels to apply (created automatically if missing).   |
| `issue_number`     | int\|null  | Populated by `sync-issues.sh`. Do not edit manually.        |

## Local Usage

### Prerequisites

- [`gh`](https://cli.github.com/) CLI installed and authenticated (`gh auth login`)
- [`jq`](https://jqlang.github.io/jq/) installed
- `GITHUB_REPOSITORY` env var set (or let the script auto-detect from `gh`)

### Sync requirements to issues

```bash
# Dry run (no changes made)
./requirements/sync-issues.sh --dry-run

# Create/update issues and project
./requirements/sync-issues.sh
```

After creating new issues, the script updates `requirements.json` with issue numbers. Commit this change.

### Post test results

```bash
# Run tests and pipe to the results script
go test ./... -json 2>&1 | ./requirements/update-results.sh
```

### Adding a new requirement

1. Add an entry to `requirements.json` with a new `id` and `"issue_number": null`.
2. Run `sync-issues.sh` (or push to main — the GitHub Action will handle it).
3. The script creates the issue and writes the number back to the JSON.

## GitHub Actions

### `requirements-sync.yml`

Runs automatically when `requirements/requirements.json` is pushed to `main`. Creates/updates issues, then commits the updated JSON back with `[skip ci]` to avoid loops.

### `requirements-results.yml`

Runs on weekdays at 06:00 UTC (and via manual dispatch). Runs `go test`, posts results to the matching issues as comments.

### Secrets

| Secret          | Required | Purpose                                                    |
|-----------------|----------|------------------------------------------------------------|
| `PROJECT_TOKEN` | Optional | PAT with `project` scope for GitHub Projects v2 operations. Falls back to `GITHUB_TOKEN` (which works for issues but not projects). |
