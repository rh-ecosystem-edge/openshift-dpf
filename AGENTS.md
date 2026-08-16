# E2E Test Authoring

## Framework
Tests live in `test/e2e/` (module `github.com/openshift-dpf/test`, package `e2e`).

Always check `dpfe2e "github.com/nvidia/doca-platform/test/e2e"` for existing `Validate*`/`Verify*` functions before writing custom logic. Prefer framework functions over reimplementing shared behaviour.

## Structure
- `Describe` name: `"TC-XXXX-NNN: <Short Description>"`
- Labels: suite label + TC-specific label — e.g. `Label("dpudeployment-lifecycle", "dpudeployment-child-immutability")`
- Always `Ordered`; `BeforeAll` must `Skip` when `dpfInput.NumberOfDPUNodes == 0`
- First `It` blocks: pre-conditions asserting the system is in a known-good state
- Last `It` block: call `waitForClusterHealth()` (or `checkClusterOperatorsHealthy`)
- All async assertions: `Eventually(func(g Gomega){...}).WithTimeout(...).WithPolling(5*time.Second).Should(Succeed())`
- Long waits (provisioning/upgrade): use dpfe2e timeouts, for example `dpfe2e.DPUDeploymentReadyTimeout`
- Document logical steps with `By("...")`, log progress with `GinkgoWriter.Printf(...)`

## Suite Globals (shared across all test files)
`ctx`, `mgmtClient`, `mgmtClientset`, `mgmtConfig`, `hostedClient`, `hostedClientset`, `hostedConfig`, `dpfInput` (`*dpfe2e.SystemTestInput`), `dpuHostWorkers []corev1.Node`, `dpuWorkers []corev1.Node`, `cfg` (`TestConfig`)

## Helpers
- helpers.go`
- `waitForClusterHealth()`, `checkClusterOperatorsHealthy()`, `checkPodsHealthyOnNodes()` — `cluster_health_test.go`
- Local utils package: `"github.com/openshift-dpf/test/utils"` (node, pod, cluster, resource)

## Labels (reuse existing; add new only if genuinely different scope)
e.g. `sanity`, `cluster-health`, `deployment`, `upstream`, `dpf-operator`, `dpudeployment`, `dpuservice`, `leader-election`, `dpudeployment-lifecycle`, `dpudeployment-bfb-update`, `dpudeployment-child-immutability`, `dpudeployment-child-recovery`, `hosted-upgrade`, `requires-nodes`, `disruptive`, `hbn`

## File Naming
`<feature>_<scenario>_test.go` — e.g. `dpudeployment_scale_test.go`