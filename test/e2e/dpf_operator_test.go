package e2e

import (
	"time"

	. "github.com/onsi/ginkgo/v2"

	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
)

var _ = Describe("DPFOperatorConfig Validation", Label("upstream", "dpf-operator"), func() {
	Context("Readiness", func() {
		It("DPFOperatorConfig is Ready", func() {
			dpfe2e.VerifyDPFOperatorConfigReady(ctx, mgmtClient, 5*time.Minute)
		})
	})

	Context("DPU Services Running", func() {
		It("expected DPU services are deployed on the DPU cluster", Label("requires-nodes"), func() {
			if len(dpuWorkers) == 0 {
				Skip("No DPU worker nodes available")
			}
			if len(dpfe2e.DPUClusterClient) == 0 {
				Skip("DPU cluster client not configured")
			}
			dpfe2e.VerifyDPUServicesDeployed(ctx, dpfe2e.DPUClusterClient[0], dpfe2e.DPFOperatorSystemNamespace)
		})
	})

	Context("System Pods", func() {
		It("expected DPF system pods are running on the management cluster", func() {
			expectedPods := []string{
				"dpf-provisioning-controller",
				"dpf-operator",
				"dpuservice-controller",
			}
			dpfe2e.VerifyClusterPods(ctx, mgmtClient, expectedPods)
		})
	})
})
