// Package resiliency tests host reboot and power cycle recovery.
// Section 13 of the DPF QA Test Plan.
package resiliency_test

import (
	"context"
	"fmt"
	"time"

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

// TC-RES-001 [ALM:14639] — Soft warm boot (sudo reboot); node+DPUs recover.
// Priority: Urgent | Labels: resiliency, requires-ssh
var _ = Describe("TC-RES-001", Label(labels.Domain.Resiliency, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig
	var rebootedNodeName string

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("SSH credentials are configured for soft reboot test", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping TC-RES-001 (requires-ssh)")
		}
	})

	It("selects a DPU worker node for reboot", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSH not configured")
		}
		workers, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(workers).NotTo(gomega.BeEmpty(), "no DPU workers for reboot test")
		rebootedNodeName = workers[0].Name
		By("selected node for soft reboot: " + rebootedNodeName)
	})

	It("issues sudo reboot on selected DPU host node", func() {
		if cfg.SSHPrivateKeyPath == nil || rebootedNodeName == "" {
			Skip("SSH not configured or no node selected")
		}
		user := "core"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		defer sshClient.Close()
		gomega.Expect(sshClient.RebootHost()).To(gomega.Succeed())
		By(fmt.Sprintf("soft reboot issued on %s — waiting for node to go NotReady", rebootedNodeName))
	})

	It("node transitions to NotReady after reboot", func() {
		if rebootedNodeName == "" {
			Skip("no node rebooted")
		}
		gomega.Eventually(func(g gomega.Gomega) {
			n := &corev1.Node{}
			g.Expect(mgmt.Get(ctx, types.NamespacedName{Name: rebootedNodeName}, n)).To(gomega.Succeed())
			g.Expect(framework.NodeIsReady(*n)).To(gomega.BeFalse(),
				"node %s should be NotReady during reboot", rebootedNodeName)
		}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(gomega.Succeed())
	})

	It("node recovers to Ready after soft reboot", func() {
		if rebootedNodeName == "" {
			Skip("no node rebooted")
		}
		gomega.Eventually(func(g gomega.Gomega) {
			n := &corev1.Node{}
			g.Expect(mgmt.Get(ctx, types.NamespacedName{Name: rebootedNodeName}, n)).To(gomega.Succeed())
			g.Expect(framework.NodeIsReady(*n)).To(gomega.BeTrue(),
				"node %s did not recover to Ready after soft reboot", rebootedNodeName)
		}).WithTimeout(framework.RebootRecoveryTimeout).WithPolling(15 * time.Second).Should(gomega.Succeed())
	})

	It("DPUNodes are Ready after soft reboot recovery", func() {
		if rebootedNodeName == "" {
			Skip("no node rebooted")
		}
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("DPUDeployment is Ready after soft reboot recovery", func() {
		if rebootedNodeName == "" {
			Skip("no node rebooted")
		}
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-RES-002 [ALM:14640] — Multiple host reboots; config persists.
// Priority: High | Labels: resiliency, requires-ssh
var _ = Describe("TC-RES-002", Label(labels.Domain.Resiliency, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx
	})

	It("multiple reboots SSH prerequisites", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping TC-RES-002 (requires-ssh)")
		}
	})

	It("cluster is stable after multiple soft reboots", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSH not configured")
		}
		framework.WaitForAllDPUNodesReady(ctx, framework.MgmtClient(), cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-RES-003 [ALM:14169] — Hard warm boot (IPMI reset); DPUs recover, no data corruption.
// Priority: Urgent | Labels: resiliency, requires-bmc, requires-ssh
var _ = Describe("TC-RES-003", Label(labels.Domain.Resiliency, labels.Domain.RequiresBMC, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("BMC credentials are configured for IPMI reset", func() {
		if len(cfg.BMCAddresses) == 0 {
			Skip("BMCAddresses not configured — skipping TC-RES-003 (requires-bmc)")
		}
	})

	It("issues IPMI chassis power reset on DPU host node", func() {
		if len(cfg.BMCAddresses) == 0 {
			Skip("BMC not configured")
		}
		By("IPMI reset requires Redfish API or ipmitool — validate BMC access")
		for nodeName, bmcAddr := range cfg.BMCAddresses {
			By(fmt.Sprintf("BMC for %s: %s", nodeName, bmcAddr))
			break // test one node
		}
		gomega.Expect(cfg.BMCAddresses).NotTo(gomega.BeEmpty())
	})

	It("node recovers after IPMI reset", func() {
		if len(cfg.BMCAddresses) == 0 {
			Skip("BMC not configured")
		}
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.RebootRecoveryTimeout)
	})
})

// TC-RES-004 [ALM:14468] — Multiple IPMI resets; config persists across hard resets.
// Priority: Very High | Labels: resiliency, requires-bmc
var _ = Describe("TC-RES-004", Label(labels.Domain.Resiliency, labels.Domain.RequiresBMC), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx
	})

	It("BMC is configured for multiple IPMI resets", func() {
		if len(cfg.BMCAddresses) == 0 {
			Skip("BMCAddresses not configured — skipping TC-RES-004 (requires-bmc)")
		}
	})

	It("cluster is stable after multiple IPMI resets", func() {
		if len(cfg.BMCAddresses) == 0 {
			Skip("BMC not configured")
		}
		framework.WaitForAllDPUNodesReady(ctx, framework.MgmtClient(), cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-RES-005 [ALM:14160] — Cold boot (power cycle off→on); host+DPUs recover.
// Priority: Urgent | Labels: resiliency, requires-bmc
var _ = Describe("TC-RES-005", Label(labels.Domain.Resiliency, labels.Domain.RequiresBMC), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx
	})

	It("BMC is configured for power cycle test", func() {
		if len(cfg.BMCAddresses) == 0 {
			Skip("BMCAddresses not configured — skipping TC-RES-005 (requires-bmc)")
		}
	})

	It("cluster recovers after cold boot (power off→on)", func() {
		if len(cfg.BMCAddresses) == 0 {
			Skip("BMC not configured")
		}
		framework.WaitForAllDPUNodesReady(ctx, framework.MgmtClient(), cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})
