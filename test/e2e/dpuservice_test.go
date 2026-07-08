package e2e

import (
	. "github.com/onsi/ginkgo/v2"

	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
)

var _ = Describe("DPUService Operations", Label("upstream", "dpuservice"), func() {
	Context("DPUService IPAM", func() {
		It("rejects invalid DPUServiceIPAM via webhook", func() {
			dpfe2e.ValidateDPUServiceIPAMCreationInvalid(ctx, dpfInput)
		})

		It("creates DPUServiceIPAM with subnet split per node and verifies NVIPAM IPPool", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUServiceIPAMCreationSubnetSplit(ctx, dpfInput)
		})

		It("creates DPUServiceIPAM with CIDR split and verifies NVIPAM CIDRPool", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUServiceIPAMCreationCidrSplit(ctx, dpfInput)
		})
	})

	Context("DPUServiceChain", func() {
		It("creates DPUServiceInterface and verifies mirroring to DPU clusters", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUServiceInterfaceCreation(ctx, dpfInput)
		})

		It("creates DPUServiceChain and verifies mirroring to DPU clusters", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUServiceChainCreation(ctx, dpfInput)
		})

		It("deletes DPUServiceChain and DPUServiceInterface and verifies cleanup", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUServiceChainDeletion(ctx, dpfInput)
		})
	})

	Context("DPUService Lifecycle", func() {
		It("creates DPUService and verifies mirroring to DPU clusters", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUServiceCreationAndMirroring(ctx, dpfInput)
		})

		It("deletes DPUService and verifies cleanup", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			dpfe2e.ValidateDPUServiceDeletion(ctx, dpfInput)
		})
	})
})
