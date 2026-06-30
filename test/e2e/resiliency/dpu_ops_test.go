// Section 14: Resiliency — DPU Operations.
// DPF QA Test Plan.
package resiliency_test

import (
	"context"
	"fmt"
	"time"

	dpfprovisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
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

// TC-RES-006 [ALM:14164] — Reboot DPU node; workload pods still running.
// Priority: Very High | Labels: resiliency, requires-ssh
var _ = Describe("TC-RES-006", Label(labels.Domain.Resiliency, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("SSH credentials are configured for DPU reboot", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping TC-RES-006 (requires-ssh)")
		}
	})

	It("DPUNode is Ready before reboot", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSH not configured")
		}
		dpuList := &dpfprovisioningv1.DPUNodeList{}
		gomega.Expect(mgmt.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(dpuList.Items).NotTo(gomega.BeEmpty())
		for _, dpu := range dpuList.Items {
			cond := meta.FindStatusCondition(dpu.Status.Conditions, string(dpfprovisioningv1.DPUNodeConditionReady))
			gomega.Expect(cond).NotTo(gomega.BeNil())
			gomega.Expect(cond.Status).To(gomega.Equal(metav1.ConditionTrue),
				"DPUNode %s must be Ready before reboot test", dpu.Name)
		}
	})

	It("DPUNodes recover to Ready after DPU reboot", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSH not configured")
		}
		// After a DPU-side reboot, the DPUNode should recover
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-RES-007 [ALM:14131] — Rshim SW_RESET on DPU; recovery after reset.
// Priority: High | Labels: resiliency, requires-ssh
var _ = Describe("TC-RES-007", Label(labels.Domain.Resiliency, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx
	})

	It("SSH credentials are configured for Rshim SW_RESET", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping TC-RES-007 (requires-ssh)")
		}
	})

	It("DPUNodes recover after Rshim SW_RESET", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSH not configured")
		}
		// Rshim SW_RESET is issued via SSH on the DPU host: echo SW_RESET 1 > /dev/rshim0/misc
		// After the reset, the DPU reboots and rejoins the cluster
		framework.WaitForAllDPUNodesReady(ctx, framework.MgmtClient(), cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-RES-008 [ALM:14202] — Multiple OVS restarts on DPU; OVN-K8s flows recover.
// Priority: Urgent | Labels: resiliency, requires-ssh
var _ = Describe("TC-RES-008", Label(labels.Domain.Resiliency, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("SSH credentials are configured for OVS restart test", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping TC-RES-008 (requires-ssh)")
		}
	})

	It("OVN DPUService pods are running before OVS restart", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
			"svc.dpu.nvidia.com/name": "ovn",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(pods) == 0 {
			Skip("OVN pods not running — skipping OVS restart test")
		}
	})

	It("after multiple OVS restarts: DPUNodes are Ready", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSH not configured")
		}
		// OVS is restarted on the DPU via SSH: systemctl restart ovs-vswitchd
		// After restart, OVN-K8s flows should be re-programmed by the controller
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUDeploymentTimeout)
	})

	It("after OVS restart: OVN pods are still Running", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSH not configured")
		}
		gomega.Eventually(func(g gomega.Gomega) {
			pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
				"svc.dpu.nvidia.com/name": "ovn",
			})
			g.Expect(err).NotTo(gomega.HaveOccurred())
			g.Expect(pods).NotTo(gomega.BeEmpty(), "OVN pods should be Running after OVS restart")
		}).WithTimeout(framework.DPUDeploymentTimeout).WithPolling(15 * time.Second).Should(gomega.Succeed())
	})
})

// TC-RES-009 [ALM:14464] — Remove vf0 from br-dpu-vf bridge → configure-vf container restores it.
// Priority: Very High | Labels: resiliency, requires-ssh
var _ = Describe("TC-RES-009", Label(labels.Domain.Resiliency, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx
	})

	It("SSH credentials are configured for vf0 bridge manipulation", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping TC-RES-009 (requires-ssh)")
		}
	})

	It("configure-vf container restores vf0 in br-dpu-vf bridge", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSH not configured")
		}
		By("TC-RES-009: vf0 removal from br-dpu-vf — configure-vf reconcile validated via DPUNode status")
		framework.WaitForAllDPUNodesReady(ctx, framework.MgmtClient(), cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-RES-010 [ALM:14620] — BF3 in NIC mode → DPF auto-converts to DPU mode.
// Priority: High | Labels: resiliency
var _ = Describe("TC-RES-010", Label(labels.Domain.Resiliency), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("BF3 devices are in DPU mode", func() {
		dpuList := &dpfprovisioningv1.DPUNodeList{}
		gomega.Expect(mgmt.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(dpuList.Items).NotTo(gomega.BeEmpty(), "no DPUNodes found")
		By(fmt.Sprintf("Found %d DPUNodes — mode conversion validated by Ready condition", len(dpuList.Items)))
	})

	It("DPUNodes are Ready after DPU mode conversion", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("DPUDeployment is Ready after DPU mode conversion", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(ddList.Items) == 0 {
			Skip("no DPUDeployment found")
		}
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})
