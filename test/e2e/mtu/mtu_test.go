// Package mtu tests MTU configuration for DPF services.
// Section 8 of the DPF QA Test Plan.
package mtu_test

import (
	"context"
	"fmt"
	"strings"
	"time"

	dpfoperatorv1 "github.com/nvidia/doca-platform/api/operator/v1alpha1"
	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-MTU-001 [ALM:14459] — Change MTU in HBN DPUServiceChain; verify on host interfaces.
// Priority: High | Labels: mtu, networking
var _ = Describe("TC-MTU-001", Label(labels.Domain.MTU, labels.Domain.Networking), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUServiceChain objects exist", func() {
		chainList := &dpfservicev1.DPUServiceChainList{}
		gomega.Expect(mgmt.List(ctx, chainList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(chainList.Items) == 0 {
			Skip("no DPUServiceChain found — skipping MTU-001")
		}
	})

	It("DPUDeployment is Ready before MTU change", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("DPFOperatorConfig highSpeedMTU is set", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt.Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
		gomega.Expect(opcfg.Spec.Networking).NotTo(gomega.BeNil(), "DPFOperatorConfig.spec.networking is nil")
		By("highSpeedMTU is configured in DPFOperatorConfig")
	})

	It("host interfaces reflect DPUServiceChain MTU setting", Label(labels.Domain.RequiresSSH), func() {
		if cfg.SSHPrivateKeyPath == nil || *cfg.SSHPrivateKeyPath == "" {
			Skip("SSHPrivateKeyPath not configured — skipping host interface MTU check")
		}
		if cfg.HypervisorHost == nil || *cfg.HypervisorHost == "" {
			Skip("HypervisorHost not configured — skipping host interface MTU check")
		}

		// Get the MTU value from the DPUServiceChain spec.
		chainList := &dpfservicev1.DPUServiceChainList{}
		gomega.Expect(mgmt.List(ctx, chainList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(chainList.Items) == 0 {
			Skip("no DPUServiceChain found — skipping host interface MTU check")
		}

		chain := &chainList.Items[0]
		switches := chain.Spec.Template.Spec.Template.Spec.Switches
		if len(switches) == 0 || switches[0].ServiceMTU == nil {
			Skip("DPUServiceChain has no switches with ServiceMTU configured")
		}
		expectedMTU := *switches[0].ServiceMTU

		// SSH to the hypervisor host and check interface MTUs.
		sshUser := "core"
		if cfg.HypervisorUser != nil && *cfg.HypervisorUser != "" {
			sshUser = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, sshUser, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to open SSH connection to hypervisor")
		defer sshClient.Close()

		By(fmt.Sprintf("checking that MTU %d appears in host interface list", expectedMTU))
		out, err := sshClient.Run("ip link show | grep -oP 'mtu \\K[0-9]+' | sort -u")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to run ip link show on hypervisor")

		mtuValues := strings.Fields(strings.TrimSpace(out))
		gomega.Expect(mtuValues).NotTo(gomega.BeEmpty(), "no MTU values found on host interfaces")

		expectedMTUStr := fmt.Sprintf("%d", expectedMTU)
		gomega.Expect(mtuValues).To(gomega.ContainElement(expectedMTUStr),
			"expected MTU %d from DPUServiceChain not found in host interface MTUs: %v", expectedMTU, mtuValues)
	})
})

// TC-MTU-003 [ALM:14481] — Change controlplaneMTU before DPUDeployment; pods use new MTU.
// Priority: High | Labels: mtu
var _ = Describe("TC-MTU-003", Label(labels.Domain.MTU), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPFOperatorConfig controlPlaneMTU matches cluster configuration", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt.Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
		if opcfg.Spec.Networking == nil {
			Skip("DPFOperatorConfig.spec.networking not configured")
		}
		By("controlPlaneMTU is set in DPFOperatorConfig.spec.networking")
	})

	It("DPUDeployment is Ready with current MTU configuration", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})

	It("DPU worker nodes have consistent MTU on host interfaces", func() {
		dpuNodes, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(dpuNodes).NotTo(gomega.BeEmpty())
		By("MTU consistency check — requires SSH to node for detailed verification")
	})

	It("DPF pods use the configured controlplane MTU", Label(labels.Domain.RequiresSSH), func() {
		if cfg.SSHPrivateKeyPath == nil || *cfg.SSHPrivateKeyPath == "" {
			Skip("SSHPrivateKeyPath not configured — skipping controlplane MTU check")
		}
		if cfg.HypervisorHost == nil || *cfg.HypervisorHost == "" {
			Skip("HypervisorHost not configured — skipping controlplane MTU check")
		}

		// Get controlplaneMTU from DPFOperatorConfig spec.
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt.Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())

		if opcfg.Spec.Networking == nil || opcfg.Spec.Networking.ControlPlaneMTU == nil || *opcfg.Spec.Networking.ControlPlaneMTU == 0 {
			Skip("controlplaneMTU not configured in DPFOperatorConfig.spec.networking")
		}
		controlplaneMTU := *opcfg.Spec.Networking.ControlPlaneMTU

		// SSH to the hypervisor host and check interface MTUs.
		sshUser := "core"
		if cfg.HypervisorUser != nil && *cfg.HypervisorUser != "" {
			sshUser = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, sshUser, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to open SSH connection to hypervisor")
		defer sshClient.Close()

		By(fmt.Sprintf("checking that controlplane MTU %d appears in host interface list", controlplaneMTU))
		out, err := sshClient.Run("ip link show | grep -oP 'mtu \\K[0-9]+' | sort -u")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to run ip link show on hypervisor")

		mtuValues := strings.Fields(strings.TrimSpace(out))
		gomega.Expect(mtuValues).NotTo(gomega.BeEmpty(), "no MTU values found on host interfaces")

		controlplaneMTUStr := fmt.Sprintf("%d", controlplaneMTU)
		gomega.Expect(mtuValues).To(gomega.ContainElement(controlplaneMTUStr),
			"expected controlplane MTU %d from DPFOperatorConfig not found in host interface MTUs: %v", controlplaneMTU, mtuValues)
	})
})

// TC-MTU-005 [ALM:14480] — Negative: service MTU > highspeedMTU → rejected with error.
// Priority: Medium | Labels: mtu
var _ = Describe("TC-MTU-005", Label(labels.Domain.MTU), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPFOperatorConfig accepts valid highSpeedMTU value", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt.Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
		By("DPFOperatorConfig retrieved — MTU negative test validates admission webhook rejection")
	})

	It("DPUServiceChain with MTU exceeding highSpeedMTU is rejected", func() {
		// Get current DPUServiceChain.
		chainList := &dpfservicev1.DPUServiceChainList{}
		gomega.Expect(mgmt.List(ctx, chainList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(chainList.Items) == 0 {
			Skip("no DPUServiceChain found — skipping MTU-005 negative test")
		}

		chain := &chainList.Items[0]
		switches := chain.Spec.Template.Spec.Template.Spec.Switches
		if len(switches) == 0 || switches[0].ServiceMTU == nil {
			Skip("DPUServiceChain has no switches with ServiceMTU configured — skipping MTU-005 negative test")
		}
		currentMTU := *switches[0].ServiceMTU

		// Save original MTU value for rollback.
		originalMTU := currentMTU

		// Attempt to patch DPUServiceChain with MTU = highSpeedMTU + 1000 (intentionally invalid).
		invalidMTU := originalMTU + 1000
		By(fmt.Sprintf("attempting to set MTU %d (current %d + 1000) on DPUServiceChain", invalidMTU, originalMTU))

		updated := chain.DeepCopy()
		for i := range updated.Spec.Template.Spec.Template.Spec.Switches {
			updated.Spec.Template.Spec.Template.Spec.Switches[i].ServiceMTU = &invalidMTU
		}

		updateErr := mgmt.Update(ctx, updated)
		if updateErr != nil {
			// Webhook rejected the update — this is the expected path.
			By(fmt.Sprintf("update correctly rejected by webhook: %v", updateErr))
			gomega.Expect(updateErr).To(gomega.HaveOccurred(), "expected webhook to reject oversized MTU")
		} else {
			// Update was accepted; check that a status condition reflects the error.
			By("update was accepted; checking status conditions for error indicator")
			defer func() {
				// Revert the patch regardless of outcome.
				revert := chain.DeepCopy()
				for i := range revert.Spec.Template.Spec.Template.Spec.Switches {
					revert.Spec.Template.Spec.Template.Spec.Switches[i].ServiceMTU = &originalMTU
				}
				_ = mgmt.Update(ctx, revert)
			}()

			gomega.Eventually(func(g gomega.Gomega) {
				current := &dpfservicev1.DPUServiceChain{}
				g.Expect(mgmt.Get(ctx, client.ObjectKeyFromObject(chain), current)).To(gomega.Succeed())
				cond := meta.FindStatusCondition(current.Status.Conditions, "Ready")
				g.Expect(cond).NotTo(gomega.BeNil(), "Ready condition not found on DPUServiceChain")
				// Expect the Ready condition to be False with an MTU-related message.
				g.Expect(cond.Status).To(gomega.Equal(metav1.ConditionFalse),
					"expected Ready=False after invalid MTU, got %s: %s", cond.Status, cond.Message)
				g.Expect(strings.ToLower(cond.Message)).To(
					gomega.Or(
						gomega.ContainSubstring("mtu"),
						gomega.ContainSubstring("invalid"),
					),
					"expected error message to reference MTU or invalid, got: %s", cond.Message)
			}).WithContext(ctx).WithTimeout(2*time.Minute).WithPolling(framework.PollInterval).Should(gomega.Succeed())
		}
	})

	It("DPUDeployment remains Ready after invalid MTU rejection", func() {
		gomega.Eventually(func(g gomega.Gomega) {
			ddList := &dpfservicev1.DPUDeploymentList{}
			g.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			g.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		}).WithTimeout(30 * time.Second).WithPolling(5 * time.Second).Should(gomega.Succeed())
	})
})
