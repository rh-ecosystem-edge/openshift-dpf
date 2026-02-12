# Skip deploy storage – saved changes

Patch file: **`skip-deploy-storage-changes.patch`**

## What it contains

- **SKIP_DEPLOY_STORAGE** option: skip LSO/LVM/ODF deployment and use existing StorageClasses.
- **Validation**: when skip is set, require **ETCD_STORAGE_CLASS** in `.env` (user-defined) and, after cluster install, check that the StorageClass exists in the cluster.

## Files changed in the patch

- `scripts/env.sh` – add `SKIP_DEPLOY_STORAGE`, require `ETCD_STORAGE_CLASS` when true
- `scripts/manifests.sh` – skip `enable_storage` when `SKIP_DEPLOY_STORAGE=true`
- `scripts/cluster.sh` – add `validate_storage_classes_available()`, skip LSO/ODF and run validation when skip is true
- `.env.example` – document the new variable
- `Makefile` – help text for the new option
- `docs/user-guide/advanced-topics.md` – “Use external storage” example updated

## Re-apply on a new branch

```bash
git checkout -b skip-deploy-storage   # or your branch name
git apply skip-deploy-storage-changes.patch
# resolve any conflicts if the base branch diverged, then commit
git add -A && git commit -m "Add SKIP_DEPLOY_STORAGE with StorageClass validation"
```

To inspect the patch without applying: `git apply --stat skip-deploy-storage-changes.patch`
