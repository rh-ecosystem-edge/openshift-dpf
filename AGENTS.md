# AGENTS.md

This file provides guidance to AI tools when working with code in this repository.

## What This Repo Is

Automation framework for deploying NVIDIA DPF (DPU Platform Framework) on Red Hat OpenShift clusters with BlueField-3 DPUs. It is entirely shell scripts and YAML manifests — no compiled language, no test suite. The entry point is `make all`, which orchestrates the full lifecycle: cluster creation via Red Hat Assisted Installer, DPF operator deployment, DPU networking setup (OVN-Kubernetes), and worker node provisioning via Bare Metal Operator/Redfish.

## Architecture

### Configuration flow

All runtime configuration flows through a single `.env` file at the repo root (gitignored). It is generated, never hand-edited:

1. `ci/env.defaults` — default value for every optional variable (`${VAR:-default}` syntax)
2. `ci/env.required` — variables with no default; generation fails if unset
3. `ci/env.template` — canonical ordered list; `envsubst` renders it into `.env`

Generate with `make generate-env` (fails if `.env` exists; use `FORCE=true` to overwrite). Validate with `make validate-env-files` (checks defaults ↔ template consistency).

When adding a new variable: add the default to `ci/env.defaults`, add a `${VAR}` line to `ci/env.template`, and if it has no sensible default add a guard to `ci/env.required`.

### Script structure

All scripts live in `scripts/` and follow a common pattern:
- Source `env.sh` (loads `.env`, validates MTU, verifies `aicli` connectivity)
- Source `utils.sh` (logging, retry, wait helpers, manifest application, libvirt wrappers)
- Define functions, then dispatch via a `case` block at the bottom when executed directly
- The Makefile calls `scripts/<name>.sh <subcommand>`

Key scripts and their responsibilities:
- `env.sh` — env loading, `.env` generation, computed/conditional variables (OLM workaround catalog, OVN-K image resolution, storage class selection)
- `utils.sh` — shared utilities: `log()`, `retry()`, `wait_for_resource()`, `wait_for_pods()`, `apply_manifest()`, `process_template()`, libvirt helpers (`lvirsh`, `lvirt_install`, `libvirt_host_cmd`)
- `cluster.sh` — Assisted Installer cluster lifecycle (create, install, wait, kubeconfig, ISO handling, day-2 cluster for workers)
- `manifests.sh` — manifest preparation and OVN manifest generation; template processing with variable substitution
- `dpf.sh` — DPF operator deployment (NFD, ArgoCD/GitOps, Maintenance Operator, Helm chart installs)
- `post-install.sh` — post-installation manifests (BFB, HBN, DTS, OVN, DPU services, observability)
- `worker.sh` — physical worker provisioning via BMO/Redfish (BareMetalHost CRs, MachineConfig, CSR approval)
- `vm.sh` — libvirt VM management (create/delete cluster VMs and worker VMs, static IP support, remote libvirt via SSH)
- `verify.sh` — deployment verification (worker nodes Ready, DPU nodes Ready in DPUCluster, DPUDeployment status)

### Manifests

`manifests/` contains YAML templates organized by deployment phase:
- `cluster-installation/` — OpenShift day-1 manifests (MachineConfigs, LSO, LVM, SR-IOV)
- `dpf-installation/` — DPF operator CRs (NFD, DPFOperatorConfig)
- `post-installation/` — DPU service definitions (BFB, HBN, DTS, OVN, DPUDeployment)
- `helm-charts-values/` — Helm values files for OVN and DPF charts
- `worker-provisioning/` — BareMetalHost and Secret templates for physical workers
- `observability/` — Grafana dashboards and monitoring operator manifests

Templates use placeholder strings (e.g., `<CLUSTER_FQDN>`, `<BFB_URL>`) that are substituted at runtime by `process_template()` or `sed`. Generated output goes to `manifests/generated/` (gitignored).

## Key Make Targets

```text
make all                  # Full deployment (logs to logs/)
make generate-env         # Generate .env from ci/ source files
make validate-env-files   # Check env.defaults ↔ env.template consistency
make create-cluster       # Create OpenShift cluster via Assisted Installer
make deploy-dpf           # Deploy DPF operator
make add-worker-nodes     # Provision physical workers via BMO/Redfish
make deploy-dpu-services  # Deploy DPU services (HBN, DTS, OVN)
make worker-status        # Check worker provisioning status
make run-dpf-sanity       # Run sanity checks
make verify-deployment    # Full verification (workers + DPU nodes + DPUDeployment)
make clean-all            # Delete cluster, VMs, and all generated files
make help                 # List all targets with descriptions
```

## Conventions

- All scripts use `set -e` and `set -o pipefail`.
- Use `log "LEVEL" "message"` (from `utils.sh`) for output — levels: INFO, WARN, ERROR, DEBUG (DEBUG only shown when `DEBUG=true`).
- Use `retry <attempts> <delay> <command>` for operations that may need retries.
- Use `apply_manifest <file>` which skips if the resource already exists (pass `true` as second arg to force apply).
- Use `check_*_exists()` helpers before creating resources (namespaces, CRDs, secrets, Helm releases).
- Sensitive values (API keys, pull secrets) are redacted in logs by `update_file_multi_replace()`.
- Libvirt operations go through `lvirsh`/`lvirt_install` wrappers that handle local vs. remote (`LIBVIRT_HOST`) transparently.
- Use `oc` to interact with the management cluster and `kd` (if available, alias to `oc --kubeconfig ~/.kube/doca.kubeconfig`) to interact with the hosted one.
- **Never use `ovs-ctl` to restart OVS on DPUs.** It wipes the database and can't reinitialize DPDK from inside a container. Instead use:
  ```bash
  oc debug node/<dpu-node-name> --kubeconfig=<hosted-kubeconfig> -- chroot /host systemctl restart ovs-vswitchd
  ```
