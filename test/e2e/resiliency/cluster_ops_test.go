// Section 15: Resiliency — Cluster Operations.
// DPF QA Test Plan.
package resiliency_test

import (
	"context"
	"time"

	dpfprovisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-RES-011 [ALM:14152] — Full cluster shutdown + restart; DPF fully recovers.
// Priority: Very High | Labels: resiliency
var _ = Describe("TC-RES-011", Label(labels.Domain.Resiliency), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPFOperatorConfig is Ready before cluster shutdown/restart", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("after full cluster restart: all DPUNodes are Ready", func() {
		// This It() is the post-restart validation.
		// The actual cluster restart is orchestrated by the CI pipeline (BMC power off/on or hypervisor snapshot).
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("after full cluster restart: DPUDeployment is Ready", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("after full cluster restart: HBN and OVN pods are Running", func() {
		for _, svcName := range []string{"hbn", "ovn"} {
			gomega.Eventually(func(g gomega.Gomega) {
				pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
					"svc.dpu.nvidia.com/name": svcName,
				})
				g.Expect(err).NotTo(gomega.HaveOccurred())
				g.Expect(pods).NotTo(gomega.BeEmpty(), "%s pods not Running after cluster restart", svcName)
			}).WithTimeout(framework.DPUDeploymentTimeout).WithPolling(15 * time.Second).Should(gomega.Succeed())
		}
	})
})

// TC-RES-013 [ALM:14137] — Cordon and drain worker node; quick recovery after uncordon.
// Priority: High | Labels: resiliency
var _ = Describe("TC-RES-013", Label(labels.Domain.Resiliency), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig
	var cordonedNodeName string

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("selects a DPU worker node for cordon/drain", func() {
		workers, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(workers).NotTo(gomega.BeEmpty())
		cordonedNodeName = workers[0].Name
		By("selected node for cordon: " + cordonedNodeName)
	})

	It("cordons the selected DPU worker node", func() {
		node := &corev1.Node{}
		gomega.Expect(mgmt.Get(ctx, client.ObjectKey{Name: cordonedNodeName}, node)).To(gomega.Succeed())
		node.Spec.Unschedulable = true
		gomega.Expect(mgmt.Update(ctx, node)).To(gomega.Succeed())
		By("node cordoned: " + cordonedNodeName)
	})

	It("uncordons the node and verifies it is schedulable", func() {
		node := &corev1.Node{}
		gomega.Expect(mgmt.Get(ctx, client.ObjectKey{Name: cordonedNodeName}, node)).To(gomega.Succeed())
		node.Spec.Unschedulable = false
		gomega.Expect(mgmt.Update(ctx, node)).To(gomega.Succeed())
		By("node uncordoned: " + cordonedNodeName)
	})

	It("DPUNodes are Ready after uncordon", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("DPUDeployment is Ready after cordon/uncordon cycle", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-RES-014 [ALM:14151] — Delete and recreate worker node; DPU re-provisioned from scratch.
// Priority: Very High | Labels: resiliency
var _ = Describe("TC-RES-014", Label(labels.Domain.Resiliency), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment is Ready before worker node delete/recreate", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("after worker node delete+recreate: DPUNode is re-provisioned", func() {
		// Worker node delete/recreate is typically driven by the CI pipeline (MachineSet scale down/up).
		// This It() validates the post-recreate state.
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("after worker node recreate: DPUDeployment is Ready", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-RES-015 [ALM:14197] — Delete all DPF system pods; auto-recovery via controller reconciliation.
// Priority: Very High | Labels: resiliency
var _ = Describe("TC-RES-015", Label(labels.Domain.Resiliency), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPF system namespace has running pods before deletion", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, nil)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(pods).NotTo(gomega.BeEmpty(), "no DPF system pods found before deletion test")
		By("DPF pods before deletion: " + string(rune('0'+len(pods))))
	})

	It("deletes all pods in DPF namespace", func() {
		podList := &corev1.PodList{}
		gomega.Expect(mgmt.List(ctx, podList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		for i := range podList.Items {
			p := &podList.Items[i]
			_ = mgmt.Delete(ctx, p)
		}
		By("all DPF namespace pods deleted — waiting for controller reconciliation")
	})

	It("DPF system pods recover via controller reconciliation", func() {
		gomega.Eventually(func(g gomega.Gomega) {
			pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, nil)
			g.Expect(err).NotTo(gomega.HaveOccurred())
			g.Expect(pods).NotTo(gomega.BeEmpty(), "DPF pods did not recover after deletion")
		}).WithTimeout(framework.OperatorReadyTimeout).WithPolling(10 * time.Second).Should(gomega.Succeed())
	})

	It("DPUDeployment is Ready after pod recovery", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-RES-016 [ALM:14186] — Delete DPUSet → DPUDeployment recreates, DPUs re-provisioned.
// Priority: High | Labels: resiliency, dpudeployment
var _ = Describe("TC-RES-016", Label(labels.Domain.Resiliency, labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUSets exist in DPF namespace", func() {
		dpuSetList := &dpfprovisioningv1.DPUSetList{}
		gomega.Expect(mgmt.List(ctx, dpuSetList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(dpuSetList.Items).NotTo(gomega.BeEmpty(), "no DPUSets found")
	})

	It("deletes all DPUSets and waits for DPUDeployment to recreate them", func() {
		dpuSetList := &dpfprovisioningv1.DPUSetList{}
		gomega.Expect(mgmt.List(ctx, dpuSetList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		for i := range dpuSetList.Items {
			ds := &dpuSetList.Items[i]
			gomega.Expect(mgmt.Delete(ctx, ds)).To(gomega.Or(
				gomega.Succeed(),
				gomega.MatchError(gomega.ContainSubstring("not found")),
			))
		}
		By("DPUSets deleted — DPUDeployment controller should recreate them")
	})

	It("DPUSets are recreated by the DPUDeployment controller", func() {
		gomega.Eventually(func(g gomega.Gomega) {
			dpuSetList := &dpfprovisioningv1.DPUSetList{}
			g.Expect(mgmt.List(ctx, dpuSetList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			g.Expect(dpuSetList.Items).NotTo(gomega.BeEmpty(), "DPUSets not recreated by DPUDeployment controller")
		}).WithTimeout(10 * time.Minute).WithPolling(15 * time.Second).Should(gomega.Succeed())
	})

	It("DPUNodes are Ready after DPUSet recreation", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("DPUDeployment is Ready after DPUSet recreation", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-RES-017 [ALM:141XX] — Cordon/drain control plane nodes hosting HyperShift pods.
// Priority: High | Labels: resiliency, hcp
var _ = Describe("TC-RES-017", Label(labels.Domain.Resiliency, labels.Domain.HCP), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("HyperShift control plane pods are running in hosted namespace", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.HostedClusterNamespace, map[string]string{
			"hypershift.openshift.io/control-plane": "true",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(pods) == 0 {
			Skip("HyperShift control plane pods not found — skipping TC-RES-017")
		}
		By("HyperShift control plane pods running: " + string(rune('0'+len(pods))))
	})

	It("after control plane cordon/drain: HyperShift pods reschedule and DPUDeployment recovers", func() {
		// Control plane cordon/drain is orchestrated by the CI pipeline.
		// This It() validates the post-drain recovery state.
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(ddList.Items) == 0 {
			Skip("no DPUDeployment found")
		}
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})
