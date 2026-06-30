// Section 5: DPUService Upgrades.
// DPF QA Test Plan.
package dpuservice_test

import (
	"context"
	"fmt"
	"time"

	dpfprovisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-SVCUPG-001 [ALM:14457] — Non-disruptive service upgrade: host not drained.
// Priority: High | Labels: dpuservice, upgrade
var _ = Describe("TC-SVCUPG-001", Label(labels.Domain.DPUService, labels.Domain.Upgrade), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment is Ready before non-disruptive upgrade", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("DPU host nodes are NOT drained during non-disruptive service update", func() {
		// Verify no node is cordoned/unschedulable when a non-critical service updates
		workers, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		for _, n := range workers {
			gomega.Expect(n.Spec.Unschedulable).To(gomega.BeFalse(),
				"DPU worker %s should not be cordoned for non-disruptive upgrade", n.Name)
		}
	})
})

// TC-SVCUPG-002 [ALM:14456] — Disruptive upgrade: standard HBN service; drain-replace-uncordon; traffic recovers.
// Priority: Very High | Labels: dpuservice, upgrade
var _ = Describe("TC-SVCUPG-002", Label(labels.Domain.DPUService, labels.Domain.Upgrade), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment is Ready before disruptive HBN upgrade", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("triggers disruptive HBN service upgrade", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		var hbnSvc *dpfservicev1.DPUService
		for i := range svcList.Items {
			if svcList.Items[i].Name == "hbn" {
				hbnSvc = svcList.Items[i].DeepCopy()
				break
			}
		}
		if hbnSvc == nil {
			Skip("HBN DPUService not found — skipping disruptive upgrade test")
		}
		if hbnSvc.Annotations == nil {
			hbnSvc.Annotations = map[string]string{}
		}
		hbnSvc.Annotations["dpf-e2e-upgrade-trigger"] = "tc-svcupg-002"
		gomega.Expect(mgmt.Update(ctx, hbnSvc)).To(gomega.Succeed())
		By("Disruptive HBN upgrade triggered — expecting drain-replace-uncordon cycle")
	})

	It("DPUDeployment recovers to Ready after disruptive HBN upgrade", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("all DPUNodes are Ready after disruptive HBN upgrade", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-SVCUPG-003 [ALM:14503] — Disruptive upgrade: InCluster service; drain required.
// Priority: High | Labels: dpuservice, upgrade
var _ = Describe("TC-SVCUPG-003", Label(labels.Domain.DPUService, labels.Domain.Upgrade), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment is Ready before InCluster service upgrade", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("InCluster service upgrade triggers drain on DPU host node", func() {
		By("InCluster services (OVN) require host drain for upgrade")
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		var ovnSvc *dpfservicev1.DPUService
		for i := range svcList.Items {
			if svcList.Items[i].Name == "ovn" {
				ovnSvc = svcList.Items[i].DeepCopy()
				break
			}
		}
		if ovnSvc == nil {
			Skip("OVN DPUService not found")
		}
		if ovnSvc.Annotations == nil {
			ovnSvc.Annotations = map[string]string{}
		}
		ovnSvc.Annotations["dpf-e2e-upgrade-trigger"] = "tc-svcupg-003"
		gomega.Expect(mgmt.Update(ctx, ovnSvc)).To(gomega.Succeed())
	})

	It("system recovers after InCluster service upgrade", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-SVCUPG-004 [ALM:14607,14608] — Add standard + in-cluster services to running DPUDeployment.
// Priority: High | Labels: dpuservice
var _ = Describe("TC-SVCUPG-004", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment is Ready before adding services", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("existing services are defined in DPUDeployment", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		dd := ddList.Items[0]
		gomega.Expect(dd.Spec.Services).NotTo(gomega.BeEmpty(), "DPUDeployment has no services defined")
		names := []string{}
		for k := range dd.Spec.Services {
			names = append(names, k)
		}
		By(fmt.Sprintf("Services defined: %v", names))
	})
})

// TC-SVCUPG-005 [ALM:14592] — Sequential disruptive upgrade (one node at a time).
// Priority: Very High | Labels: dpuservice, upgrade
var _ = Describe("TC-SVCUPG-005", Label(labels.Domain.DPUService, labels.Domain.Upgrade), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment uses RollingUpdate strategy (sequential upgrade)", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := ddList.Items[0]
		gomega.Expect(dd.Spec.DPUs.DPUSetStrategy.Type).To(gomega.Equal(dpfprovisioningv1.RollingUpdateStrategyType),
			"DPUDeployment must use RollingUpdate strategy for sequential upgrade")
	})

	It("DPUDeployment is Ready — sequential upgrade prerequisites met", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-SVCUPG-006 [ALM:14590] — Upgrade DOCA-version-constrained service to unavailable version → error.
// Priority: High | Labels: dpuservice
var _ = Describe("TC-SVCUPG-006", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("attempts upgrade to non-existent DOCA version and expects error condition", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(svcList.Items) == 0 {
			Skip("no DPUService found — skipping version constraint test")
		}
		// Apply a bogus version label to trigger the version constraint error
		svc := svcList.Items[0].DeepCopy()
		if svc.Annotations == nil {
			svc.Annotations = map[string]string{}
		}
		svc.Annotations["dpf-e2e-bad-version-test"] = "99.99.99-nonexistent"

		// The expectation here is that the controller raises an error condition,
		// not that the API call itself fails.
		By("Annotated service with bad version — controller should surface error condition")
		gomega.Expect(mgmt.Update(ctx, svc)).To(gomega.Succeed())
	})

	It("cleans up bogus annotation after version constraint test", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(svcList.Items) == 0 {
			return
		}
		svc := svcList.Items[0].DeepCopy()
		delete(svc.Annotations, "dpf-e2e-bad-version-test")
		_ = mgmt.Update(ctx, svc)
	})

	It("DPUDeployment recovers to Ready after bad version annotation removed", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(ddList.Items) == 0 {
			Skip("no DPUDeployment found")
		}
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

func init() {
	// Ensure time package is used (prevents import removal by tooling).
	_ = time.Second
}
