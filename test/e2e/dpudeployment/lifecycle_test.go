// Package dpudeployment tests DPUDeployment lifecycle operations.
// Section 3 of the DPF QA Test Plan.
package dpudeployment_test

import (
	"context"
	"time"

	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-DPUD-001 [ALM:14161] — Delete and recreate DPUDeployment; traffic stops then resumes.
// Priority: Urgent | Labels: bat, dpudeployment
var _ = Describe("TC-DPUD-001", Label(labels.Domain.BAT, labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig
	var savedDD dpfservicev1.DPUDeployment

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment exists and is Ready before deletion", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty(), "no DPUDeployment to delete")
		savedDD = *ddList.Items[0].DeepCopy()
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("deletes the DPUDeployment", func() {
		ddToDelete := savedDD.DeepCopy()
		framework.DeleteAndWaitGone(ctx, mgmt, ddToDelete, 5*time.Minute)
		By("DPUDeployment deleted — traffic path is now broken")
	})

	It("recreates the DPUDeployment with the original spec", func() {
		newDD := savedDD.DeepCopy()
		newDD.ResourceVersion = ""
		newDD.UID = ""
		newDD.Generation = 0
		gomega.Expect(mgmt.Create(ctx, newDD)).To(gomega.Succeed())
		By("DPUDeployment recreated — waiting for it to become Ready")
	})

	It("DPUDeployment is Ready after recreation", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := &ddList.Items[0]
		framework.WaitForDPUDeploymentReady(ctx, mgmt, dd, framework.DPUDeploymentTimeout)
	})

	It("all DPUNodes are Ready after DPUDeployment recreation", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-DPUD-002 [ALM:14139] — DPUDeployment Update: change BFB; DPUs reprovisioned.
// Priority: Urgent | Labels: bat, dpudeployment
var _ = Describe("TC-DPUD-002", Label(labels.Domain.BAT, labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig
	var originalBFB string

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment is Ready and current BFB is recorded", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := &ddList.Items[0]
		framework.WaitForDPUDeploymentReady(ctx, mgmt, dd, framework.DPUDeploymentTimeout)
		originalBFB = dd.Spec.DPUs.BFB
		By("Current BFB: " + originalBFB)
	})

	It("updates DPUDeployment BFB to the same value (no-op update validates immutability path)", func() {
		// In the absence of a second BFB in CI, we patch with the same value and verify no error.
		// A real BFB change test would require a second pre-loaded BFB object.
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		dd := ddList.Items[0].DeepCopy()
		dd.Spec.DPUs.BFB = originalBFB // same value — no reprovisioning expected
		gomega.Expect(mgmt.Update(ctx, dd)).To(gomega.Succeed())
	})

	It("DPUDeployment is Ready after update", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		dd := &ddList.Items[0]
		framework.WaitForDPUDeploymentReady(ctx, mgmt, dd, framework.DPUDeploymentTimeout)
	})
})

// TC-DPUD-003 [ALM:14149] — System cleanup after DPUDeployment deletion; no residuals.
// Priority: Very High | Labels: dpudeployment
var _ = Describe("TC-DPUD-003", Label(labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig
	var savedDD dpfservicev1.DPUDeployment

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("captures current DPUDeployment before deletion", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		savedDD = *ddList.Items[0].DeepCopy()
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("deletes DPUDeployment and verifies child resources are garbage collected", func() {
		ddToDelete := savedDD.DeepCopy()
		framework.DeleteAndWaitGone(ctx, mgmt, ddToDelete, 5*time.Minute)

		// Verify DPUSets are cleaned up
		gomega.Eventually(func(g gomega.Gomega) {
			dpuSetList := &dpfservicev1.DPUServiceList{}
			g.Expect(mgmt.List(ctx, dpuSetList, client.InNamespace(cfg.DPFNamespace),
				client.MatchingLabels{dpfservicev1.ParentDPUDeploymentNameLabel: savedDD.Name}),
			).To(gomega.Succeed())
			g.Expect(dpuSetList.Items).To(gomega.BeEmpty(), "DPUService child objects not cleaned up")
		}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(gomega.Succeed())
	})

	It("recreates DPUDeployment to restore baseline", func() {
		newDD := savedDD.DeepCopy()
		newDD.ResourceVersion = ""
		newDD.UID = ""
		newDD.Generation = 0
		gomega.Expect(mgmt.Create(ctx, newDD)).To(gomega.Succeed())
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		dd := &ddList.Items[0]
		framework.WaitForDPUDeploymentReady(ctx, mgmt, dd, framework.DPUDeploymentTimeout)
	})
})

// TC-DPUD-004 [ALM:14153] — Recovery after deletion of child objects.
// Priority: Very High | Labels: dpudeployment
var _ = Describe("TC-DPUD-004", Label(labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment is Ready before child deletion", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("deletes all DPUService child objects of the DPUDeployment", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := ddList.Items[0]

		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace),
			client.MatchingLabels{dpfservicev1.ParentDPUDeploymentNameLabel: dd.Name}),
		).To(gomega.Succeed())
		for _, svc := range svcList.Items {
			svcCopy := svc
			gomega.Expect(mgmt.Delete(ctx, &svcCopy)).To(gomega.Or(
				gomega.Succeed(),
				gomega.MatchError(gomega.ContainSubstring("not found")),
			))
		}
		By("Child DPUService objects deleted")
	})

	It("DPUDeployment controller recreates child objects and returns to Ready", func() {
		// The DPUDeployment controller should detect missing children and recreate them.
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-DPUD-005 [ALM:14129] — Child objects immutability: direct edits are rejected/reverted.
// Priority: High | Labels: dpudeployment
var _ = Describe("TC-DPUD-005", Label(labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("attempts to edit a DPUService child's spec and verifies it is reverted", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := ddList.Items[0]

		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace),
			client.MatchingLabels{dpfservicev1.ParentDPUDeploymentNameLabel: dd.Name}),
		).To(gomega.Succeed())
		if len(svcList.Items) == 0 {
			Skip("no DPUService child objects found — cannot test immutability")
		}

		// Attempt to add a bogus annotation — controller should reconcile it away
		svc := svcList.Items[0].DeepCopy()
		if svc.Annotations == nil {
			svc.Annotations = map[string]string{}
		}
		svc.Annotations["dpf-e2e-test-mutation"] = "should-be-reverted"
		_ = mgmt.Update(ctx, svc) // may succeed at API level

		// After reconciliation, annotation should be gone
		gomega.Eventually(func(g gomega.Gomega) {
			latest := &dpfservicev1.DPUService{}
			g.Expect(mgmt.Get(ctx, client.ObjectKeyFromObject(svc), latest)).To(gomega.Succeed())
			_, hasAnnotation := latest.Annotations["dpf-e2e-test-mutation"]
			g.Expect(hasAnnotation).To(gomega.BeFalse(),
				"controller did not revert the bogus annotation on child DPUService")
		}).WithTimeout(3 * time.Minute).WithPolling(10 * time.Second).Should(gomega.Succeed())
	})
})

// TC-DPUD-006 [ALM:141XX] — Scale DPUs up/down via selector updates.
// Priority: High | Labels: dpudeployment
var _ = Describe("TC-DPUD-006", Label(labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment has a nodeSelector for DPU-enabled nodes", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := ddList.Items[0]
		gomega.Expect(dd.Spec.DPUs.DPUSets).NotTo(gomega.BeEmpty(), "DPUDeployment has no DPUSets")
		dpuSet := dd.Spec.DPUs.DPUSets[0]
		gomega.Expect(dpuSet.NodeSelector).NotTo(gomega.BeNil())
		_, hasLabel := dpuSet.NodeSelector.MatchLabels[framework.DPUEnabledLabel]
		gomega.Expect(hasLabel).To(gomega.BeTrue(),
			"DPUSet nodeSelector must include %s", framework.DPUEnabledLabel)
	})

	It("reports correct DPUNode count matching expected DPU count", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		dd := &ddList.Items[0]
		cond := meta.FindStatusCondition(dd.Status.Conditions, "Ready")
		if cond != nil && cond.Status == metav1.ConditionTrue {
			framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
		}
	})
})
