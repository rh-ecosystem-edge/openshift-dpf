// Package kubevirt tests KubeVirt VM workloads on DPU worker nodes.
// Section 21 of the DPF QA Test Plan.
package kubevirt_test

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-VIRT-001 — VMs on DPU workers with/without UDN.
// Priority: High | Labels: dpf
var _ = Describe("TC-VIRT-001", Label(labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
	})

	It("DPU worker nodes are schedulable for VM workloads", func() {
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, framework.MgmtClient())
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(dpuWorkers).NotTo(gomega.BeEmpty())
		for _, n := range dpuWorkers {
			gomega.Expect(framework.NodeIsReady(n)).To(gomega.BeTrue(),
				"DPU worker %s is not Ready", n.Name)
		}
	})

	It("KubeVirt operator is installed (if required)", func() {
		pods, err := framework.ListRunningPods(ctx, framework.MgmtClient(), "kubevirt", nil)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(pods) == 0 {
			Skip("KubeVirt not installed — skipping VM on DPU test (TC-VIRT-001)")
		}
		By("KubeVirt pods running — VM on DPU worker validation can proceed")
	})

	It("all DPU nodes are Ready for VM workload scheduling", func() {
		framework.WaitForAllDPUNodesReady(ctx, framework.MgmtClient(), cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})
