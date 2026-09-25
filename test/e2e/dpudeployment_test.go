package e2e

import (
	. "github.com/onsi/ginkgo/v2"

	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
)

var _ = Describe("DPUDeployment Lifecycle", Label("upstream", "dpudeployment"), func() {
	Context("Readiness", Label("requires-nodes"), func() {
		It("DPUDeployment is Ready", func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.VerifyDPUDeploymentIsReady(ctx, dpfInput)
		})
	})

	Context("Disruptive Upgrade - Standard DPUService (Drain)", Label("requires-nodes", "disruptive"), func() {
		It("validates disruptive upgrade flow with drain node effect", func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUDeploymentDPUServiceDisruptiveUpgradeDrain(ctx, dpfInput)
		})
	})

	Context("Disruptive Upgrade - Standard DPUService (Hold)", Label("requires-nodes", "disruptive"), func() {
		It("validates disruptive upgrade flow with hold node effect", func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUDeploymentDPUServiceDisruptiveUpgradeHold(ctx, dpfInput)
		})
	})

	Context("Disruptive Upgrade - InCluster DPUService", Label("requires-nodes", "disruptive"), func() {
		It("validates disruptive upgrade for in-cluster DPU services", func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUDeploymentInClusterDPUServiceDisruptiveUpgrade(ctx, dpfInput)
		})
	})

	Context("Disruptive Upgrade - DPUServiceChain (Drain)", Label("requires-nodes", "disruptive"), func() {
		It("validates disruptive upgrade of DPUServiceChain with drain", func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUDeploymentDPUServiceChainDisruptiveUpgradeDrain(ctx, dpfInput)
		})
	})

	Context("Disruptive Upgrade - Bad Configuration Recovery", Label("requires-nodes", "disruptive"), func() {
		It("validates recovery from bad DPUService configuration", func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUDeploymentDPUServiceDisruptiveUpgradeBadConfigurationAndBack(ctx, dpfInput)
		})
	})
})
