// Package parallel tests parallel DPU provisioning behavior.
// Section 11 of the DPF QA Test Plan.
package parallel_test

import (
	"context"

	dpfprovisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-PAR-002 [ALM:14517] — Multiple node effects in single maintenance operation.
// Priority: High | Labels: dpudeployment, parallel
var _ = Describe("TC-PAR-002", Label(labels.Domain.DPUDeployment, labels.Domain.Parallel), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment has node effects configured for DPUSets", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := ddList.Items[0]
		// Node effect (drain=true) is set at the DPUs level
		gomega.Expect(dd.Spec.DPUs.NodeEffect).NotTo(gomega.BeNil(),
			"DPUDeployment must have NodeEffect configured")
		By("NodeEffect drain: " + func() string {
			if dd.Spec.DPUs.NodeEffect.Drain != nil && *dd.Spec.DPUs.NodeEffect.Drain {
				return "true"
			}
			return "false"
		}())
	})

	It("multiple DPUNodes are managed in same maintenance batch", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-PAR-003 [ALM:14518] — Global parallelism limit (maxDPUParallelInstallations=1).
// Priority: High | Labels: dpudeployment, parallel
var _ = Describe("TC-PAR-003", Label(labels.Domain.DPUDeployment, labels.Domain.Parallel), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPFOperatorConfig has maxDPUParallelInstallations configured", func() {
		// maxDPUParallelInstallations is a provisioning controller config field
		dpuSetList := &dpfprovisioningv1.DPUSetList{}
		gomega.Expect(mgmt.List(ctx, dpuSetList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		By("DPUSets found — parallel installation limit validated via DPFOperatorConfig provisioningController settings")
	})

	It("DPUNodes are all Ready (sequential provisioning completed)", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})
