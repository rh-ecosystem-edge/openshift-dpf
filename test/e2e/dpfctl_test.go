package e2e

import (
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const dpfctlAllTargetBugURL = "https://partners.nvidia.com/Bug/ViewBug/6439986?siteID=310998"

var _ = Describe("TC-LOG-001: dpfctl SOS Report Collection", Label("dpfctl"), func() {
	It("collects a standalone SOS report from every host worker", func() {
		if len(dpuHostWorkers) == 0 {
			Skip("SOS collection requires at least one DPU-enabled host worker")
		}

		hostNodes := make([]string, 0, len(dpuHostWorkers))
		for _, node := range dpuHostWorkers {
			hostNodes = append(hostNodes, node.Name)
		}

		By("Collecting a standalone SOS report from every discovered host worker")
		Expect(runStandaloneDPFCTLSOSReports(ctx, osCommandRunner{}, cfg.Kubeconfig, nil, hostNodes, nil)).To(Succeed())
	})

	It("collects a standalone SOS report from every DPU worker", func() {
		if len(dpuWorkers) == 0 {
			Skip("SOS collection requires at least one ready DPU worker")
		}

		dpuNodes := make([]string, 0, len(dpuWorkers))
		for _, node := range dpuWorkers {
			dpuNodes = append(dpuNodes, node.Name)
		}

		By("Collecting a standalone SOS report from every discovered DPU worker")
		Expect(runStandaloneDPFCTLSOSReports(ctx, osCommandRunner{}, cfg.Kubeconfig, hostedKubeconfigBytes, nil, dpuNodes)).To(Succeed())
	})

	It("collects standalone SOS reports from all targets", func() {
		Skip(fmt.Sprintf("NVBUG 6439986: all-target dpfctl SOS collection is disabled until the known issue is fixed: %s", dpfctlAllTargetBugURL))
	})
})
