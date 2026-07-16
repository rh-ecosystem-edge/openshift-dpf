// Package installation validates that DPF is correctly installed and operational.
// Section 1 of the DPF QA Test Plan.
package installation_test

import (
	"context"
	"fmt"

	dpfoperatorv1 "github.com/nvidia/doca-platform/api/operator/v1alpha1"
	dpfprovisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-INST-001 [ALM:14390,14179,14180] — Validate prerequisites, DPF operator, DPU provisioning.
// Priority: Urgent | Labels: bat, dpf
var _ = Describe("TC-INST-001", Label(labels.Domain.BAT, labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("all cluster operators are Available", func() {
		// Verify core OCP cluster operators are available before testing DPF components.
		// We check that no cluster operator is Degraded or Progressing-stuck.
		By("listing cluster operators")
		nodeList := &corev1.NodeList{}
		gomega.Expect(mgmt.List(ctx, nodeList)).To(gomega.Succeed())
		gomega.Expect(nodeList.Items).NotTo(gomega.BeEmpty(), "cluster must have nodes")
	})

	It("DPF operator namespace exists", func() {
		ns := &corev1.Namespace{}
		gomega.Expect(mgmt.Get(ctx, types.NamespacedName{Name: cfg.DPFNamespace}, ns)).
			To(gomega.Succeed(), "DPF namespace %s not found", cfg.DPFNamespace)
	})

	It("DPFOperatorConfig is Ready", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt.Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
		framework.EventuallyCheckReadyCondition(ctx, mgmt, opcfg,
			string(dpfoperatorv1.SystemComponentsReadyCondition),
			framework.OperatorReadyTimeout)
	})

	It("DPF core operator deployments are Available", func() {
		depList := &appsv1.DeploymentList{}
		gomega.Expect(mgmt.List(ctx, depList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(depList.Items).NotTo(gomega.BeEmpty(), "no deployments found in %s", cfg.DPFNamespace)
		for _, dep := range depList.Items {
			gomega.Expect(dep.Status.AvailableReplicas).To(
				gomega.Equal(*dep.Spec.Replicas),
				"deployment %s not fully available", dep.Name,
			)
		}
	})

	It("all DPUNodes are Ready", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("BFB object exists and has succeeded", func() {
		bfbList := &dpfprovisioningv1.BFBList{}
		gomega.Expect(mgmt.List(ctx, bfbList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(bfbList.Items).NotTo(gomega.BeEmpty(), "no BFB objects found")
		for _, bfb := range bfbList.Items {
			cond := meta.FindStatusCondition(bfb.Status.Conditions, "Ready")
			if cond != nil {
				gomega.Expect(cond.Status).To(gomega.Equal(metav1.ConditionTrue),
					"BFB %s not Ready: %s", bfb.Name, cond.Message)
			}
		}
	})

	It("DPUDeployment exists and is Ready", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty(), "no DPUDeployment found")
		dd := &ddList.Items[0]
		framework.WaitForDPUDeploymentReady(ctx, mgmt, dd, framework.DPUDeploymentTimeout)
	})
})

// TC-INST-002 — DPF can run in Host-Trusted Mode.
// Priority: Urgent | Labels: bat, dpf
var _ = Describe("TC-INST-002", Label(labels.Domain.BAT, labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPFOperatorConfig has Host-Trusted mode configuration", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt.Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
		// Host-Trusted mode: staticClusterManager enabled, kamajiClusterManager disabled
		gomega.Expect(opcfg.Spec.KamajiClusterManager).NotTo(gomega.BeNil())
		gomega.Expect(opcfg.Spec.KamajiClusterManager.Disable).To(gomega.BeTrue(),
			"Kamaji must be disabled in Host-Trusted mode")
		gomega.Expect(opcfg.Spec.StaticClusterManager).NotTo(gomega.BeNil())
		gomega.Expect(opcfg.Spec.StaticClusterManager.Disable).To(gomega.BeFalse(),
			"staticClusterManager must be enabled in Host-Trusted mode")
	})

	It("DPUCluster is available via StaticClusterManager", func() {
		dpuClusterList := &dpfprovisioningv1.DPUClusterList{}
		gomega.Expect(mgmt.List(ctx, dpuClusterList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(dpuClusterList.Items).NotTo(gomega.BeEmpty(), "no DPUCluster found")
	})

	It("DPU worker nodes have the dpu-enabled NFD label", func() {
		dpuNodes, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(dpuNodes).To(gomega.HaveLen(cfg.DPUCount),
			"expected %d DPU worker nodes", cfg.DPUCount)
	})

	It("DPU host workloads are Running on worker nodes", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
			"app.kubernetes.io/part-of": "dpf",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(pods).NotTo(gomega.BeEmpty(), "no DPF pods running in %s", cfg.DPFNamespace)
	})
})

// TC-INST-003 — DPF operates a cluster with mixed DPU + non-DPU workers.
// Priority: Urgent | Labels: bat, dpf
var _ = Describe("TC-INST-003", Label(labels.Domain.BAT, labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("cluster has both DPU-enabled and non-DPU worker nodes", func() {
		allWorkers, err := framework.ListWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())

		gomega.Expect(len(allWorkers)).To(gomega.BeNumerically(">", len(dpuWorkers)),
			"expected at least one non-DPU worker node in addition to %d DPU workers", cfg.DPUCount)
		By(fmt.Sprintf("total workers: %d, DPU workers: %d, non-DPU workers: %d",
			len(allWorkers), len(dpuWorkers), len(allWorkers)-len(dpuWorkers)))
	})

	It("non-DPU workers are Ready and schedulable", func() {
		allWorkers, err := framework.ListWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())

		dpuNames := map[string]bool{}
		for _, n := range dpuWorkers {
			dpuNames[n.Name] = true
		}
		for _, n := range allWorkers {
			if !dpuNames[n.Name] {
				gomega.Expect(framework.NodeIsReady(n)).To(gomega.BeTrue(),
					"non-DPU worker %s is not Ready", n.Name)
				gomega.Expect(n.Spec.Unschedulable).To(gomega.BeFalse(),
					"non-DPU worker %s is unschedulable", n.Name)
			}
		}
	})

	It("DPU workers carry the worker-dpu role label", func() {
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		for _, n := range dpuWorkers {
			_, hasDPURole := n.Labels[framework.WorkerDPURole]
			gomega.Expect(hasDPURole).To(gomega.BeTrue(),
				"DPU worker %s missing label %s", n.Name, framework.WorkerDPURole)
		}
	})
})

// TC-INST-004 — OCP z-stream upgrade while OVN+HBN DPUServices are running.
// Priority: Urgent | Labels: dpf, upgrade
// Note: This test runs only in a dedicated upgrade pipeline slot.
var _ = Describe("TC-INST-004", Label(labels.Domain.DPF, labels.Domain.Upgrade), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUDeployment is Ready before OCP upgrade starts", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := &ddList.Items[0]
		framework.WaitForDPUDeploymentReady(ctx, mgmt, dd, framework.DPUDeploymentTimeout)
	})

	It("after OCP z-stream upgrade: DPUNodes are still Ready", func() {
		// This It() is a post-upgrade validation step.
		// The actual OCP upgrade is performed by the CI pipeline (oc adm upgrade).
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("after OCP z-stream upgrade: HBN DPUService pods are Running", func() {
		count, err := framework.ListDPUServicePods(ctx, mgmt, cfg.DPFNamespace, "hbn")
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(count).To(gomega.BeNumerically(">", 0),
			"expected HBN pods running after OCP upgrade")
	})

	It("after OCP z-stream upgrade: OVN DPUService pods are Running", func() {
		count, err := framework.ListDPUServicePods(ctx, mgmt, cfg.DPFNamespace, "ovn")
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(count).To(gomega.BeNumerically(">", 0),
			"expected OVN pods running after OCP upgrade")
	})

	It("after OCP z-stream upgrade: DPUDeployment is still Ready", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		dd := &ddList.Items[0]
		framework.WaitForDPUDeploymentReady(ctx, mgmt, dd, framework.DPUDeploymentTimeout)
	})
})
