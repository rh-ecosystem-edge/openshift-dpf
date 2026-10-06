---
name: e2e-test-implementation
description: Implement or update a DPF Go/Ginkgo end-to-end test under test/e2e using the repository's client, lifecycle, helper, and validation conventions.
---

# E2E test implementation

Use this workflow when adding or changing a DPF E2E test under `test/e2e/`. It is repository-local and tool-neutral so coding agents and human contributors can use the same guidance. It includes a Codex-specific Plan-mode requirement because this workflow has required user-decision checkpoints. Do not apply it to shell deployment changes or unit-only changes unless the request also changes the E2E suite.

## Required planning gate

This workflow requires user-decision checkpoints before implementation.

- In Codex, begin in Plan mode. This enables `request_user_input` for unresolved assumptions and destructive-operation decisions.
- In other agent environments, use the platform's equivalent planning and user-question mechanism before continuing.
- Do not begin scenario-specific discovery, editing, or validation until target environment, reuse, assertions, timeouts, cleanup, and destructive-operation decisions are resolved.

Treat user-supplied manual steps as acceptance criteria and a coverage baseline, not as an inflexible script. Map every applicable manual step to an automated action or assertion, but validate the sequence against the target environment and existing test behavior. Add missing preconditions, readiness checks, cleanup, safety gates, and assertions when needed. If a manual step is inaccurate, unsafe, ambiguous, or not applicable, explain the deviation and ask the user before proceeding.

For the documented scenario:

1. Search the entire Go test codebase under `test/` for equivalent behavior before adding code.
2. Decide whether the operation is generic and useful to later tests. Reuse an existing utility, improve an existing generic utility without specializing it, or introduce a new generic utility only when justified.
3. Validate the documented order and complete the flow where necessary; do not blindly reproduce incomplete or incorrect instructions. Review timeouts, expected output, assertions, readiness checks, and cleanup. Consult the user if the sequence or expected result is unclear or appears wrong.
4. Record an explicit target map: management control plane, management DPU host, hosted DPU worker, or external power-management endpoint. Do not infer that similarly named resources belong to the same cluster.
5. Ask the user about every unresolved assumption or decision point. In Claude use `AskUserQuestion`; in Codex use `request_user_input` in Plan mode.

Use environment-neutral discovery, idempotent cleanup, and secret-safe diagnostics. Do not hardcode node, namespace, BareMetalHost, DPU, VM, or credential values, and do not expose secrets in commands or logs. For destructive work, define the opt-in gate, pre-mutation safety checks, recovery mapping, and interruption cleanup before writing the mutation.

## Discover the local contract

Read these files before editing:

1. The root `AGENTS.md`.
2. `test/e2e/AGENTS.md`.
3. `test/e2e/README.md`.
4. The closest existing test for the same resource and operation.
5. `test/e2e/helpers.go` and the relevant health/readiness helpers.

## Reuse upstream logic first

Before writing any custom assertion, polling loop, resource lookup, readiness check, or lifecycle operation, search the upstream `dpfe2e.*` package for an existing function that already implements it. Inspect the function's behavior and prerequisites, then reuse it when it covers the requested scenario. This includes `dpfe2e.Validate*`, `dpfe2e.Verify*`, wait, cleanup, and resource-discovery logic—not only functions whose names begin with `Validate` or `Verify`.

Only add custom logic when no suitable `dpfe2e.*` function exists or when the test needs a narrower assertion than the upstream function provides. Keep that custom logic focused on the test's service-specific behavior, and explain the distinction in the code when it is not obvious. Preserve unrelated worktree changes and do not refactor neighboring tests unless requested.

Before adding a precondition or skip, inspect the helpers already called by the test hook and trace the values they check back to suite initialization. Do not repeat a condition that an existing helper already guarantees, even if the helper checks an equivalent value through a different variable. For example, `skipIfClusterNotReadyForDPUReprovisioning()` skips when `dpuHostWorkers` is empty, and suite setup sets `dpfInput.NumberOfDPUNodes` from `len(dpuHostWorkers)`, so a second zero-DPU skip in the same `BeforeAll` is redundant. Keep independent test-specific skips, such as a missing optional configuration value, before the shared readiness helper.

## Design the test

Map the requested scenario to explicit preconditions, mutation, rollout verification, and cleanup. If the requested steps are ambiguous in a way that changes what should be asserted, ask for clarification rather than silently substituting a different check.

Make the Ginkgo narrative self-explanatory. Every `Describe`, `Context`, `It`, and `By` must state the action being performed and the behavior being proven, so a reviewer or new contributor can follow the scenario without reverse-engineering the implementation.

For a test that changes shared cluster configuration, use an ordered Ginkgo container with this lifecycle:

1. In `BeforeAll`, use the existing topology/preflight helper when it covers the required DPU topology; add a direct topology skip only when no called helper covers that condition. Run independent, test-specific configuration skips first.
2. Assert the initial deployment, generated resources, pods, and cluster health are ready.
3. Capture a copy of the original configuration and any resource/pod UIDs needed to prove replacement.
4. Apply the requested update through the appropriate client.
5. Wait with `Eventually` for a new generated resource revision to become Ready.
6. Require new resource or pod UIDs, and verify readiness on every expected node.
7. Verify the new settings and final cluster health.
8. Restore the original configuration in `AfterAll`, then wait for and verify the restored revision, pod replacement, and cluster health.

Make `AfterAll` idempotent: return if the original state was never captured or the current configuration already matches it. Do not make restoration depend on a final `It` block. `DeferCleanup` is acceptable for per-spec cleanup and should not be introduced into a shared-state ordered update when `AfterAll` expresses the lifecycle more clearly.

## Place code correctly

- Use `mgmtClient` for DPF custom resources and `hostedClient` for hosted-cluster workloads.
- Put generic listing, UID tracking, pod readiness, and polling support in `test/e2e/helpers.go`.
- Keep service-specific parsing, patching, and expected-value assertions beside the test that owns them.
- Prefer existing suite helpers such as `isReady`, `waitForClusterHealth`, and `waitForOVNKPodsReady`.
- Use resource labels and UIDs to identify generated DPUService revisions; object names alone do not prove a rollout.
- For pod restarts, capture UIDs per node before mutation and require a new Ready pod on every expected DPU worker afterward.
- Use `By(...)` for meaningful scenario steps and `Eventually` for asynchronous controller convergence. Avoid fixed sleeps unless an existing helper requires one.
- Give every new scenario a unique Ginkgo label. When adding a label, document it in `test/e2e/README.md`; if that README has no label list, add a concise list documenting all suite labels so users can discover available selections.

## Validate the change

From `test/` run:

```bash
gofmt -d e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go test -run '^$' ./e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go test ./e2e/
GOCACHE=/tmp/openshift-dpf-go-build GOTOOLCHAIN=auto go vet ./e2e/
```

From the repository root run:

```bash
git diff --check
```

Only claim live E2E validation when the test actually ran against a configured cluster. In the final report, identify the changed test/helper files, summarize the scenario-to-assertion mapping, list validation performed, and call out any unavailable live-cluster validation.
