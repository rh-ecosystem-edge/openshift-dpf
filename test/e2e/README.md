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

The Makefile defaults to `E2E_GO_LABEL_FILTER=dpudeployment-lifecycle`. Select the
new backported cases explicitly, or pass an empty filter to run the whole suite:

```bash
make test-go-e2e E2E_GO_LABEL_FILTER='update-ovn-dpuservice || update-dpuserviceipam || dpfctl'
make test-go-e2e E2E_GO_LABEL_FILTER=
```

### Available labels

| Labels | Coverage |
| --- | --- |
| `deployment`, `installation-mixed-workers` | Deployment and mixed DPU/non-DPU workers |
| `cluster-health` | Management/hosted operators and DPU-host pod health |
| `sanity`, `hbn` | Connectivity checks and cross-node HBN ping specs |
| `dpudeployment-lifecycle` | DPUDeployment recreation and stateful update cases |
| `dpudeployment-bfb-update`, `dpudeployment-child-recovery`, `dpudeployment-child-immutability`, `dpudeployment-selector-scaling` | Individual DPUDeployment update/recovery cases |
| `dpuservice`, `update-hbn-dpuservice`, `update-ovn-dpuservice`, `service-chain-path-update`, `update-dpuserviceipam` | Service cases; TC-SVC-002 toggles OVN egress IP and TC-SVC-004 changes the pool1 gateway index |
| `mtu`, `mtu-controlplane` | Control-plane MTU update |
| `hosted-upgrade` | Hosted-cluster upgrade |
| `dpfctl` | TC-LOG-001 per-node SOS collection |
| `upstream`, `dpf-operator`, `dpudeployment`, `leader-election` | Imported doca-platform scenarios |
| `requires-nodes`, `disruptive` | Additional selectors for imported scenarios |

TC-SVC-002 verifies new Ready OVN service and pod UIDs, then restores the original
Helm values in `AfterAll`. TC-SVC-004 requires the deployed `pool1` /29 allocations,
verifies that existing HBN pods retain their IPs and UIDs, reprovisions a DPU to
observe the updated gateway, and restores the original pool and DPU networking.
Both scenarios mutate shared deployment state and require a healthy live cluster.

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
