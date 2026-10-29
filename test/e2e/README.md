# DPF E2E tests

The tests in this directory validate an already-installed DPF environment on two OpenShift clusters:

- The management cluster owns DPF resources such as `DPUDeployment`, `DPUService`, and `DPUServiceConfiguration`.
- The hosted cluster runs the DPU workloads and their pods.

The suite creates both clients in `e2e_suite_test.go`. Test configuration is loaded from `.env.test` (or the file supplied with `-env-file`), and `KUBECONFIG` must identify the management cluster. The hosted-cluster kubeconfig is extracted from the configured management cluster.

## Test organization

- `e2e_suite_test.go` — suite setup, clients, DPU worker discovery, and cleanup tracking.
- `config.go` — test environment configuration.
- `helpers.go` — helpers shared by multiple tests.
- `cluster_health_test.go` — cluster and DPU worker health gates.
- `dpfctl_test.go` — TC-LOG-001 standalone per-node SOS collection selected by the `dpfctl` label; TC-LOG-002 standalone `describe all` runs from `AfterSuite` for every normally completed suite.
- `dpudeployment_*_test.go` — DPUDeployment lifecycle and update tests.
- `dpuservice_*_test.go` — DPUService, service-chain, and service-configuration tests.
- `*_unit_test.go` — tests that do not require a live cluster.

Use the closest existing test as the implementation model. Keep the test case ID in the `Describe` name and add labels that allow the case to be selected independently.

## Stateful update-test lifecycle

Stateful tests should use an ordered container with this lifecycle:

```text
BeforeAll
  └─ topology skip

preconditions
  └─ deployment, generated resources, pods, and cluster health are ready

mutation
  └─ capture original state, then update the shared configuration

verification
  └─ new generated revision is Ready
  └─ pods have new UIDs and are Ready
  └─ updated settings are visible
  └─ cluster is healthy

AfterAll
  └─ restore original state
  └─ wait for restored revision and pod replacement
  └─ verify original settings and cluster health
```

`AfterAll` must be idempotent. It should return when the original state was never captured or the resource already matches that state. This is important because a failed or skipped `It` must not leave shared DPF configuration modified for later tests.

For generated DPU services, compare resource UIDs captured before and after the update. For pods, capture UIDs per node and require a new Ready pod on every expected DPU worker. Names alone are insufficient because controllers may reuse naming patterns.

## Running checks

From the repository's `test/` directory:

```bash
gofmt -d e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go test -run '^$' ./e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go test ./e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go vet ./e2e/
```

To focus a live Ginkgo run, pass the normal Go test flags, for example:

```bash
go test ./e2e -ginkgo.focus 'TC-SVC-002'
```

To run TC-LOG-001 followed by the suite-wide TC-LOG-002 report:

```bash
go test ./e2e -ginkgo.label-filter=dpfctl
```

TC-LOG-001 runs the pinned standalone client with dpfctl's documented default `ghcr.io/nvidia/sosreport:latest` image. It executes `sosreport collect --nodes <host>` once for every discovered host and `sosreport collect --target dpu --nodes <dpu>` once for every discovered DPU, with a `4Gi` container memory limit; host Jobs retain a 30-minute deadline while DPU Jobs have a one-hour deadline. The all-target spec is skipped with the NVIDIA bug 6439986 reference until that issue is fixed. A missing worker type skips only its corresponding SOS spec; individual host and DPU collection failures remain blocking.

Standalone dpfctl must use the management-cluster kubeconfig even for `--target dpu`: it discovers the `DPUCluster` on the management cluster, reads its hosted-cluster kubeconfig Secret, and injects that hosted kubeconfig into the DPU SOS Job. A missing optional `/etc/dpf-defaults.yaml` warning on stderr does not fail the test; only a non-zero command result or missing/empty archive does. Collection uses `--cleanup=false` so a failed task can save the SOS init-container output, its resolved image and `imageID`, and `oc describe pods` before cleanup. Every task then runs case-ID-scoped dpfctl cleanup and verifies that no matching Jobs, Pods, or Secrets remain; successful tasks do not create failure-diagnostic artifacts.

TC-LOG-002 runs standalone `dpfctl describe all` from `AfterSuite`, so it also runs when another label is selected or the label filter is empty. It does not depend on worker discovery. Logs and SOS archives are stored under `${ARTIFACT_DIR}/dpfctl/`. Like any `AfterSuite` hook, TC-LOG-002 cannot run if the test process is terminated by a hard timeout or signal.

A compile-only or unit run does not prove that a live update rolled out. Report live E2E results separately and include the cluster/configuration prerequisites used.

## Adding a test

Before opening a change, confirm:

- The test maps each required scenario step to an `It` block or a `By(...)` step.
- Management and hosted resources use the correct client.
- Shared state is captured before mutation and restored in `AfterAll`.
- Generic discovery, UID, readiness, and polling logic is in `helpers.go`.
- Generated resources and pods are verified by status and identity, not only by object names.
- The test ends with a meaningful cluster-health assertion.
- Formatting, compile-only tests, unit tests, vet, and `git diff --check` pass.

## TC-INST-003 VM worker validation

Select `installation-mixed-workers`. The Go test runs in the Prow container and calls `make add-vm-workers` there. If no dedicated Ready non-DPU worker exists, the target provisions one VM through remote libvirt using the cluster profile. The test uses a unique VM prefix, scoped CSR approval, and two ping pods in a test-owned namespace. Cleanup removes its VM, Node, and recorded Assisted Installer resources; an existing non-DPU worker is reused and preserved.

For a fork worktree on the hypervisor, copy `.env.test` and `.env` from the current CI checkout with mode 600; ensure the pull-secret and SSH-public-key paths in `.env` resolve from the new worktree. `KUBECONFIG` in `.env.test` must be an existing absolute management-cluster path. If generating `.env.test`, export that `KUBECONFIG` first. Verify the commit and run in the PR worktree:

```bash
git -C "$TEST_DIR" log -1 --oneline
mkdir -p "$TEST_DIR/artifacts"
ARTIFACT_DIR="$TEST_DIR/artifacts" make -C "$TEST_DIR" test-go-e2e \
  E2E_GO_LABEL_FILTER=installation-mixed-workers E2E_ENV_FILE="$TEST_DIR/.env.test"
```

Check afterward that the base Assisted Installer record retains its original status and the temporary VM and Node are absent. This local run exercises local libvirt; Prow validation is required for the cluster-profile path. Offline worker checks: `python3 scripts/tests/test_vm_workers.py`, `bash -n scripts/vm-workers.sh`, and `shellcheck scripts/vm-workers.sh`.
