// Package conformance tests OCP conformance on a DPF cluster.
// Section 20 of the DPF QA Test Plan.
package conformance_test

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-CONF-001 — OCP conformance suite on cluster with 2 DPU workers.
// Priority: High | Labels: dpf
var _ = Describe("TC-CONF-001", Label(labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
	})

	It("cluster has expected number of DPU worker nodes for conformance run", func() {
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, framework.MgmtClient())
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(dpuWorkers).To(gomega.HaveLen(cfg.DPUCount),
			"conformance requires %d DPU workers", cfg.DPUCount)
	})

	It("all DPU workers are Ready before conformance run", func() {
		framework.WaitForAllDPUNodesReady(ctx, framework.MgmtClient(), cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("OCP conformance suite is invoked externally (oc adm run-tests)", func() {
		// The actual conformance suite is run by 'oc adm run-tests' or 'openshift-tests'.
		// This It() validates pre-conditions and anchors the TC in the test suite.
		By("Pre-conditions for TC-CONF-001 validated — OCP conformance suite runs externally via openshift-tests")
	})
})
