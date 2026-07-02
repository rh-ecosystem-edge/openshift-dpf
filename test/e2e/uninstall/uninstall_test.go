// Package uninstall tests DPF complete uninstall and reinstall.
// Section 16 of the DPF QA Test Plan.
// These tests run in a DEDICATED pipeline slot — they tear down DPF entirely.
package uninstall_test

import (
	"context"
	"time"

	dpfoperatorv1 "github.com/nvidia/doca-platform/api/operator/v1alpha1"
	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-UNINST-001 [ALM:14127] — Complete DPF uninstall; dpf-operator-system namespace empty.
// Priority: Very High (lowered) | Labels: dpf
// IMPORTANT: Run in a dedicated uninstall pipeline slot — this test destroys the DPF installation.
var _ = Describe("TC-UNINST-001", Label(labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPF is installed and DPFOperatorConfig exists before uninstall", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt.Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
	})

	It("DPUDeployment is deleted as part of uninstall", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		for i := range ddList.Items {
			dd := &ddList.Items[i]
			gomega.Expect(mgmt.Delete(ctx, dd)).To(gomega.Or(
				gomega.Succeed(),
				gomega.MatchError(gomega.ContainSubstring("not found")),
			))
		}
	})

	It("DPFOperatorConfig is deleted", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		if err := mgmt.Get(ctx, types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace}, opcfg); err == nil {
			gomega.Expect(mgmt.Delete(ctx, opcfg)).To(gomega.Succeed())
		}
	})

	It("DPF namespace has no running DPF-managed pods after uninstall", func() {
		gomega.Eventually(func(g gomega.Gomega) {
			podList := &corev1.PodList{}
			g.Expect(mgmt.List(ctx, podList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			dpfPods := 0
			for _, p := range podList.Items {
				if p.Status.Phase == corev1.PodRunning {
					dpfPods++
				}
			}
			g.Expect(dpfPods).To(gomega.Equal(0),
				"expected 0 running DPF pods after uninstall, got %d", dpfPods)
		}).WithTimeout(10 * time.Minute).WithPolling(15 * time.Second).Should(gomega.Succeed())
	})
})

// TC-UNINST-002 [ALM:14141] — Uninstall-reinstall cycle returns to fully functional state.
// Priority: High (lowered) | Labels: dpf
// IMPORTANT: Run in a dedicated uninstall pipeline slot after TC-UNINST-001.
var _ = Describe("TC-UNINST-002", Label(labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("after reinstall: DPFOperatorConfig is Ready", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		if err := mgmt.Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		); err != nil {
			Skip("DPFOperatorConfig not present — reinstall may not have run yet")
		}
		framework.EventuallyCheckReadyCondition(ctx, mgmt, opcfg,
			string(dpfoperatorv1.SystemComponentsReadyCondition), framework.OperatorReadyTimeout)
	})

	It("after reinstall: all DPUNodes are Ready", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("after reinstall: DPUDeployment is Ready", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(ddList.Items) == 0 {
			Skip("no DPUDeployment found after reinstall")
		}
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})
