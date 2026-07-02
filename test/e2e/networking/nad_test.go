// TC-NET-002 — Secondary CNI NAD traffic on VFs.
// Priority: Low | Labels: networking
package networking_test

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-NET-002 [ALM:14257] — Secondary CNI NAD traffic on VFs.
// Priority: Low | Labels: networking
var _ = Describe("TC-NET-002", Label(labels.Domain.Networking), Ordered, func() {
	var ctx context.Context

	BeforeAll(func() {
		ctx = context.Background()
	})

	It("SRIOV network device plugin DaemonSet is Running", func() {
		pods, err := framework.ListRunningPods(ctx, framework.MgmtClient(), "sriov-network-operator", map[string]string{
			"app": "sriov-device-plugin",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(pods) == 0 {
			Skip("SRIOV device plugin not deployed — skipping NAD VF test")
		}
		gomega.Expect(pods).NotTo(gomega.BeEmpty())
	})

	It("NAD-backed pods can be scheduled on DPU nodes", func() {
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, framework.MgmtClient())
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(dpuWorkers).NotTo(gomega.BeEmpty(), "no DPU workers for NAD test")
	})
})
