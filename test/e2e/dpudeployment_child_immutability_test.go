package e2e

import (
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"

	"sigs.k8s.io/controller-runtime/pkg/client"
)

// TC-DPUD-005: Child Objects Immutability During Updates
//
// Validates that the DPUDeployment reconciliation loop reverts direct modifications
// to its managed child objects (DPUService, DPUServiceChain, DPUSet). Each child
// is patched individually; the test asserts the change is undone without downtime.
var _ = Describe("TC-DPUD-005: Child Objects Immutability During Updates", Label("dpudeployment-lifecycle", "dpudeployment-child-immutability"), Ordered, func() {

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available, skipping TC-DPUD-005")
		}
	})

	It("pre-condition: should have DPUDeployment in Ready state", func() {
		dpuDeployment := getDPUDeployment()
		Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
			"DPUDeployment must be Ready before immutability test")
	})

	// ── DPUService ────────────────────────────────────────────────────────────

	It("should revert unauthorized DPUService spec changes", func() {
		ownedBy := client.MatchingLabels{
			dpuservicev1.ParentDPUDeploymentNameLabel: cfg.DPFNamespace + "_" + cfg.DPUDeploymentName,
		}
		svcList := &dpuservicev1.DPUServiceList{}
		Expect(mgmtClient.List(ctx, svcList,
			client.InNamespace(cfg.DPFNamespace), ownedBy)).To(Succeed())
		Expect(svcList.Items).NotTo(BeEmpty(), "no DPUServices owned by DPUDeployment found")

		svc := &svcList.Items[0]
		originalVersion := svc.Spec.HelmChart.Source.Version
		newVersion := originalVersion + "-immutability-test"

		By(fmt.Sprintf("Patching DPUService %s: helmChart.source.version %q → %q",
			svc.Name, originalVersion, newVersion))
		patch := client.MergeFrom(svc.DeepCopy())
		svc.Spec.HelmChart.Source.Version = newVersion
		Expect(mgmtClient.Patch(ctx, svc, patch)).To(Succeed())
		GinkgoWriter.Printf("DPUService %s patched to version %q\n", svc.Name, newVersion)

		By("Waiting for DPUService helmChart version to revert to original")
		svcName := svc.Name
		Eventually(func(g Gomega) {
			current := &dpuservicev1.DPUService{}
			g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      svcName,
			}, current)).To(Succeed())
			g.Expect(current.Spec.HelmChart.Source.Version).To(Equal(originalVersion),
				"DPUService version should revert from %q back to %q",
				newVersion, originalVersion)
		}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(Succeed())

		GinkgoWriter.Printf("DPUService %s version reverted to %q\n", svcName, originalVersion)
	})

	// ── DPUServiceChain ───────────────────────────────────────────────────────

	It("should revert unauthorized DPUServiceChain spec changes", func() {
		ownedBy := client.MatchingLabels{
			dpuservicev1.ParentDPUDeploymentNameLabel: cfg.DPFNamespace + "_" + cfg.DPUDeploymentName,
		}
		chainList := &dpuservicev1.DPUServiceChainList{}
		Expect(mgmtClient.List(ctx, chainList,
			client.InNamespace(cfg.DPFNamespace), ownedBy)).To(Succeed())
		Expect(chainList.Items).NotTo(BeEmpty(), "no DPUServiceChains owned by DPUDeployment found")

		chain := &chainList.Items[0]
		switches := chain.Spec.Template.Spec.Template.Spec.Switches

		if len(switches) == 0 {
			Skip(fmt.Sprintf("DPUServiceChain %s has no switches configured, skipping serviceMTU check",
				chain.Name))
		}

		// Capture the original MTU value; nil means "not set".
		var originalMTUVal *int
		if switches[0].ServiceMTU != nil {
			v := *switches[0].ServiceMTU
			originalMTUVal = &v
		}
		newMTU := 9000
		if originalMTUVal != nil && *originalMTUVal == 9000 {
			newMTU = 1500
		}

		By(fmt.Sprintf("Patching DPUServiceChain %s: switches[0].serviceMTU → %d",
			chain.Name, newMTU))
		patch := client.MergeFrom(chain.DeepCopy())
		chain.Spec.Template.Spec.Template.Spec.Switches[0].ServiceMTU = &newMTU
		Expect(mgmtClient.Patch(ctx, chain, patch)).To(Succeed())
		GinkgoWriter.Printf("DPUServiceChain %s patched: serviceMTU=%d\n", chain.Name, newMTU)

		By("Waiting for DPUServiceChain serviceMTU to revert to original")
		chainName := chain.Name
		Eventually(func(g Gomega) {
			current := &dpuservicev1.DPUServiceChain{}
			g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      chainName,
			}, current)).To(Succeed())

			actualSwitches := current.Spec.Template.Spec.Template.Spec.Switches
			if originalMTUVal == nil {
				if len(actualSwitches) > 0 {
					g.Expect(actualSwitches[0].ServiceMTU).To(BeNil(),
						"DPUServiceChain serviceMTU should revert to nil (unset)")
				}
			} else {
				g.Expect(len(actualSwitches)).To(BeNumerically(">", 0),
					"DPUServiceChain should still have switches after revert")
				g.Expect(actualSwitches[0].ServiceMTU).NotTo(BeNil(),
					"DPUServiceChain serviceMTU should be set after revert")
				g.Expect(*actualSwitches[0].ServiceMTU).To(Equal(*originalMTUVal),
					"DPUServiceChain serviceMTU should revert from %d to %d",
					newMTU, *originalMTUVal)
			}
		}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(Succeed())

		GinkgoWriter.Printf("DPUServiceChain %s serviceMTU reverted\n", chainName)
	})

	// ── DPUSet ────────────────────────────────────────────────────────────────

	It("should revert unauthorized DPUSet spec changes", func() {
		dpuSetList := &provisioningv1.DPUSetList{}
		Expect(mgmtClient.List(ctx, dpuSetList,
			client.InNamespace(cfg.DPFNamespace))).To(Succeed())
		Expect(dpuSetList.Items).NotTo(BeEmpty(), "no DPUSets found in namespace")

		dpuSet := &dpuSetList.Items[0]

		if dpuSet.Spec.DPUTemplate.Spec.NodeEffect.Drain == nil {
			Skip(fmt.Sprintf("DPUSet %s does not use drain nodeEffect, skipping", dpuSet.Name))
		}

		originalDrain := *dpuSet.Spec.DPUTemplate.Spec.NodeEffect.Drain
		newDrain := !originalDrain

		By(fmt.Sprintf("Patching DPUSet %s: nodeEffect.drain %v → %v",
			dpuSet.Name, originalDrain, newDrain))
		patch := client.MergeFrom(dpuSet.DeepCopy())
		dpuSet.Spec.DPUTemplate.Spec.NodeEffect.Drain = &newDrain
		Expect(mgmtClient.Patch(ctx, dpuSet, patch)).To(Succeed())
		GinkgoWriter.Printf("DPUSet %s patched: drain=%v\n", dpuSet.Name, newDrain)

		By("Waiting for DPUSet nodeEffect.drain to revert to original")
		dpuSetName := dpuSet.Name
		Eventually(func(g Gomega) {
			current := &provisioningv1.DPUSet{}
			g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      dpuSetName,
			}, current)).To(Succeed())
			g.Expect(current.Spec.DPUTemplate.Spec.NodeEffect.Drain).NotTo(BeNil(),
				"DPUSet drain field should be present after revert")
			g.Expect(*current.Spec.DPUTemplate.Spec.NodeEffect.Drain).To(Equal(originalDrain),
				"DPUSet drain should revert from %v back to %v", newDrain, originalDrain)
		}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(Succeed())

		GinkgoWriter.Printf("DPUSet %s drain reverted to %v\n", dpuSetName, originalDrain)
	})

	// ── Post-immutability assertions ──────────────────────────────────────────

	It("should have DPUDeployment still in Ready state after modification attempts", func() {
		Eventually(func(g Gomega) {
			dpuDeployment := getDPUDeployment()
			g.Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
				"DPUDeployment should remain Ready after child immutability test")
		}).WithTimeout(5*time.Minute).WithPolling(10*time.Second).Should(Succeed())
	})

	It("should have a healthy cluster after immutability verification", func() {
		waitForClusterHealth()
	})
})
