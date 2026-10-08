# E2E test instructions

These instructions apply to all files under `test/e2e/`.

## Before editing

- Read the root `AGENTS.md`, this file, and [`README.md`](README.md).
- Find the closest existing test by resource and lifecycle. For example, use `dpuservice_hbn_update_test.go` for a DPUService update and `dpudeployment_selector_scaling_test.go` for an update that must restore shared cluster state.
- Reuse existing suite helpers and upstream `dpfe2e.Validate*`/`Verify*` functions before adding custom logic.
- Treat the management cluster and hosted cluster as separate targets. Use `mgmtClient` for DPF custom resources and `hostedClient` for workload pods and hosted-cluster resources.

## Suite context

`e2e_suite_test.go` initializes these shared values in `BeforeSuite`:

- `ctx`: suite context.
- `cfg`: test configuration, including `DPFNamespace` and `DPUDeploymentName`.
- `mgmtClient`/`mgmtClientset`: management-cluster clients.
- `hostedClient`/`hostedClientset`: hosted-cluster clients.
- `dpfInput`: DPF state discovered from the live cluster.
- `dpuHostWorkers`: management-cluster DPU-enabled host workers.
- `dpuWorkers`: ready DPU workers in the hosted cluster.

The suite requires a configured management-cluster kubeconfig and a live deployment. Compile-only checks and unit tests are safe without a cluster; a full E2E run is not.

## Test structure

For a stateful test, use an `Ordered` container with this shape:

1. `BeforeAll`: skip when the required DPU topology is absent.
2. Initial preconditions: assert the DPUDeployment, relevant resources, pods, and cluster health are ready.
3. Capture the original configuration before mutating it. Copy byte slices or other mutable values rather than retaining a live object reference.
4. Apply the requested update using the controller client and describe meaningful operations with `By(...)`.
5. Wait for the controller-generated resource revision to appear and become Ready.
6. Verify rollout using stable identity, normally resource or pod UIDs, rather than only names or timestamps.
7. Verify the new configuration and cluster health.
8. `AfterAll`: restore the original shared configuration and wait for the restored generated resources, pods, and cluster health.

Use `AfterAll` for cleanup of shared cluster state in an `Ordered` test. This keeps restoration active when a later `It` fails or is skipped and avoids making restoration depend on a final assertion block. Make the hook idempotent: do nothing when the original state was never captured or the current state already matches it. Do not add explicit restore `It` blocks when the restore is lifecycle cleanup.

`DeferCleanup` remains appropriate for cleanup scoped to an individual spec or for existing tests whose lifecycle specifically requires it. Do not refactor unrelated tests merely to change their cleanup style.

## Helpers and assertions

- Put functions reusable across two or more tests in `helpers.go`, with focused unit coverage where practical.
- Keep resource-specific parsing, patching, and assertions in the resource's test file.
- Use `isReady`, `waitForClusterHealth`, `waitForOVNKPodsReady`, and existing discovery helpers where applicable.
- When testing a generated DPUService, identify it with the DPUDeployment/service labels and compare UIDs captured before the update.
- When testing a pod restart, capture pod UIDs by node before the change and require a new Ready pod on every expected node afterward.
- Use `Eventually` for asynchronous controller and pod convergence. Prefer the existing upstream or suite timeout constants over arbitrary short sleeps.
- Assert the configuration object, the generated resource status, pod readiness, and final cluster stability when the test changes a service configuration.

## Validation

From `test/`:

```bash
gofmt -d e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go test -run '^$' ./e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go test ./e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go vet ./e2e/
```

Also run `git diff --check` from the repository root. Only report live E2E validation when the test was actually run against a configured cluster.
