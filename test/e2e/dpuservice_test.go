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
			if dpfInput.IPPoolDPUServiceIPAM == nil {
				Skip("No ipv4Subnet DPUServiceIPAM is available as an upstream IPPool test template")
			}
			if len(dpfe2e.DPUClusterClient) == 0 {
				Skip("DPU cluster client not configured for upstream DPUService tests")
			}
			dpfe2e.ValidateDPUServiceIPAMCreationSubnetSplit(ctx, dpfInput)
		})

		It("creates DPUServiceIPAM with CIDR split and verifies NVIPAM CIDRPool", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			if dpfInput.CIDRDPUServiceIPAM == nil {
				Skip("No network-mode DPUServiceIPAM is available as an upstream CIDRPool test template")
			}
			if len(dpfe2e.DPUClusterClient) == 0 || len(dpfInput.DPUClusters) == 0 || dpfe2e.HostClusterRESTClient == nil {
				Skip("DPU cluster metrics prerequisites are not configured for upstream DPUService tests")
			}
			dpfe2e.ValidateDPUServiceIPAMCreationCidrSplit(ctx, dpfInput)
		})
	})

	Context("DPUServiceChain", func() {
		It("creates DPUServiceInterface and verifies mirroring to DPU clusters", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			if dpfInput.DPUServiceInterface == nil {
				Skip("No DPUServiceInterface is available as an upstream test template")
			}
			if len(dpfe2e.DPUClusterClient) == 0 {
				Skip("DPU cluster client not configured for upstream DPUService tests")
			}
			dpfe2e.ValidateDPUServiceInterfaceCreation(ctx, dpfInput)
		})

		It("creates DPUServiceChain and verifies mirroring to DPU clusters", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			if dpfInput.DPUServiceChain == nil {
				Skip("No DPUServiceChain is available as an upstream test template")
			}
			if len(dpfe2e.DPUClusterClient) == 0 {
				Skip("DPU cluster client not configured for upstream DPUService tests")
			}
			dpfe2e.ValidateDPUServiceChainCreation(ctx, dpfInput)
		})

		It("deletes DPUServiceChain and DPUServiceInterface and verifies cleanup", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			if dpfInput.DPUServiceInterface == nil || dpfInput.DPUServiceChain == nil {
				Skip("DPUServiceInterface or DPUServiceChain upstream test template is unavailable")
			}
			if len(dpfe2e.DPUClusterClient) == 0 {
				Skip("DPU cluster client not configured for upstream DPUService tests")
			}
			dpfe2e.ValidateDPUServiceChainDeletion(ctx, dpfInput)
		})
	})

	Context("DPUService Lifecycle", func() {
		It("creates DPUService and verifies mirroring to DPU clusters", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			if dpfInput.DPUService == nil || dpfInput.DPUServiceInterface == nil || len(dpfInput.PullSecretNames) == 0 {
				Skip("DPUService lifecycle upstream test templates or pull-secret configuration are unavailable")
			}
			if len(dpfe2e.DPUClusterClient) == 0 {
				Skip("DPU cluster client not configured for upstream DPUService tests")
			}
			dpfe2e.ValidateDPUServiceCreationAndMirroring(ctx, dpfInput)
		})

		It("deletes DPUService and verifies cleanup", Label("requires-nodes"), func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available")
			}
			if dpfInput.DPUService == nil || dpfInput.DPUServiceInterface == nil || len(dpfInput.PullSecretNames) == 0 {
				Skip("DPUService lifecycle upstream test templates or pull-secret configuration are unavailable")
			}
			if len(dpfe2e.DPUClusterClient) == 0 {
				Skip("DPU cluster client not configured for upstream DPUService tests")
			}
			dpfe2e.ValidateDPUServiceDeletion(ctx, dpfInput)
		})
	})
})
