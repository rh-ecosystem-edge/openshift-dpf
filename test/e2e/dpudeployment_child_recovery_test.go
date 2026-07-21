package e2e

import (
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// TC-DPUD-004: System Recovery After Deletion of Child Objects
//
// Verifies the DPUDeployment reconciliation loop: deleting owned child objects
// (DPUServiceChain, DPUSet, DPUService) one type at a time triggers automatic
// recreation with the same properties. DPUs are not reprovisioned.
var _ = Describe("TC-DPUD-004: System Recovery After Deletion of Child Objects", Label("dpudeployment-lifecycle", "dpudeployment-child-recovery"), Ordered, func() {

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available, skipping TC-DPUD-004")
		}
	})

	It("should have DPUDeployment in Ready state before deletion test", func() {
		dpuDeployment := getDPUDeployment()
		Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
			"DPUDeployment must be Ready before child deletion test")
	})

	It("should have all DPUs in Ready phase before deletion test", func() {
		expectedDPUs := len(dpuHostWorkers)
		dpuList := &provisioningv1.DPUList{}
		Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())

		readyCount := 0
		for _, dpu := range dpuList.Items {
			if dpu.Status.Phase == provisioningv1.DPUReady {
				readyCount++
			}
		}
		Expect(readyCount).To(BeNumerically(">=", expectedDPUs),
			"expected at least %d DPUs Ready, got %d", expectedDPUs, readyCount)
	})

	// ── DPUServiceChain ──────────────────────────────────────────────────────

	It("should auto-recreate DPUServiceChains after deletion", func() {
		ownedBy := client.MatchingLabels{
			dpuservicev1.ParentDPUDeploymentNameLabel: cfg.DPUDeploymentName,
		}

		chainList := &dpuservicev1.DPUServiceChainList{}
		Expect(mgmtClient.List(ctx, chainList,
			client.InNamespace(cfg.DPFNamespace), ownedBy)).To(Succeed())
		Expect(chainList.Items).NotTo(BeEmpty(), "no DPUServiceChains owned by DPUDeployment found")

		originalCount := len(chainList.Items)
		originalUIDs := make(map[types.UID]bool, originalCount)
		for _, c := range chainList.Items {
			originalUIDs[c.UID] = true
		}

		By("Deleting all owned DPUServiceChains")
		for i := range chainList.Items {
			Expect(mgmtClient.Delete(ctx, &chainList.Items[i])).To(Succeed(),
				"failed to delete DPUServiceChain %s", chainList.Items[i].Name)
			GinkgoWriter.Printf("Deleted DPUServiceChain %s\n", chainList.Items[i].Name)
		}

		By("Waiting for DPUServiceChains to be recreated and Ready")
		Eventually(func(g Gomega) {
			newList := &dpuservicev1.DPUServiceChainList{}
			g.Expect(mgmtClient.List(ctx, newList,
				client.InNamespace(cfg.DPFNamespace), ownedBy)).To(Succeed())
			g.Expect(len(newList.Items)).To(BeNumerically(">=", originalCount),
				"expected %d DPUServiceChain(s), got %d", originalCount, len(newList.Items))

			readyCount := 0
			for _, c := range newList.Items {
				if isReady(c.Status.Conditions) && !originalUIDs[c.UID] {
					readyCount++
				}
			}
			g.Expect(readyCount).To(BeNumerically(">=", originalCount),
				"waiting for %d recreated DPUServiceChain(s) to be Ready, got %d",
				originalCount, readyCount)
		}).WithTimeout(5*time.Minute).WithPolling(5*time.Second).Should(Succeed())

		GinkgoWriter.Printf("DPUServiceChains auto-recreated and Ready\n")
	})

	// ── DPUSet ───────────────────────────────────────────────────────────────

	It("should auto-recreate DPUSets after deletion", func() {
		dpuSetList := &provisioningv1.DPUSetList{}
		Expect(mgmtClient.List(ctx, dpuSetList,
			client.InNamespace(cfg.DPFNamespace))).To(Succeed())
		Expect(dpuSetList.Items).NotTo(BeEmpty(), "no DPUSets found in namespace")

		originalCount := len(dpuSetList.Items)
		originalUIDs := make(map[types.UID]bool, originalCount)
		for _, s := range dpuSetList.Items {
			originalUIDs[s.UID] = true
		}

		By("Deleting all DPUSets")
		for i := range dpuSetList.Items {
			Expect(mgmtClient.Delete(ctx, &dpuSetList.Items[i])).To(Succeed(),
				"failed to delete DPUSet %s", dpuSetList.Items[i].Name)
			GinkgoWriter.Printf("Deleted DPUSet %s\n", dpuSetList.Items[i].Name)
		}

		By("Waiting for DPUSets to be recreated and Ready")
		Eventually(func(g Gomega) {
			newList := &provisioningv1.DPUSetList{}
			g.Expect(mgmtClient.List(ctx, newList,
				client.InNamespace(cfg.DPFNamespace))).To(Succeed())
			g.Expect(len(newList.Items)).To(BeNumerically(">=", originalCount),
				"expected %d DPUSet(s), got %d", originalCount, len(newList.Items))

			readyCount := 0
			for _, s := range newList.Items {
				if !originalUIDs[s.UID] {
					ready := false
					for _, c := range s.Status.Conditions {
						if c.Type == "Ready" && c.Status == metav1.ConditionTrue {
							ready = true
							break
						}
					}
					if ready {
						readyCount++
					}
				}
			}
			g.Expect(readyCount).To(BeNumerically(">=", originalCount),
				"waiting for %d recreated DPUSet(s) to be Ready, got %d",
				originalCount, readyCount)
		}).WithTimeout(5*time.Minute).WithPolling(5*time.Second).Should(Succeed())

		GinkgoWriter.Printf("DPUSets auto-recreated and Ready\n")
	})

	// ── DPUService ───────────────────────────────────────────────────────────

	It("should auto-recreate DPUServices after deletion", func() {
		ownedBy := client.MatchingLabels{
			dpuservicev1.ParentDPUDeploymentNameLabel: cfg.DPUDeploymentName,
		}

		svcList := &dpuservicev1.DPUServiceList{}
		Expect(mgmtClient.List(ctx, svcList,
			client.InNamespace(cfg.DPFNamespace), ownedBy)).To(Succeed())
		Expect(svcList.Items).NotTo(BeEmpty(), "no DPUServices owned by DPUDeployment found")

		originalCount := len(svcList.Items)
		originalUIDs := make(map[types.UID]bool, originalCount)
		for _, s := range svcList.Items {
			originalUIDs[s.UID] = true
		}

		By("Deleting all owned DPUServices")
		for i := range svcList.Items {
			Expect(mgmtClient.Delete(ctx, &svcList.Items[i])).To(Succeed(),
				"failed to delete DPUService %s", svcList.Items[i].Name)
			GinkgoWriter.Printf("Deleted DPUService %s\n", svcList.Items[i].Name)
		}

		// DPUService deletion (HBN in particular) causes worker nodes to go
		// SchedulingDisabled temporarily — this is expected behavior. The nodes
		// recover once the DPUService is recreated and Ready.
		By("Waiting for DPUServices to be recreated and Ready")
		Eventually(func(g Gomega) {
			newList := &dpuservicev1.DPUServiceList{}
			g.Expect(mgmtClient.List(ctx, newList,
				client.InNamespace(cfg.DPFNamespace), ownedBy)).To(Succeed())
			g.Expect(len(newList.Items)).To(BeNumerically(">=", originalCount),
				"expected %d DPUService(s), got %d", originalCount, len(newList.Items))

			readyCount := 0
			for _, s := range newList.Items {
				if isReady(s.Status.Conditions) && !originalUIDs[s.UID] {
					readyCount++
				}
			}
			g.Expect(readyCount).To(BeNumerically(">=", originalCount),
				"waiting for %d recreated DPUService(s) to be Ready, got %d",
				originalCount, readyCount)
		}).WithTimeout(10*time.Minute).WithPolling(10*time.Second).Should(Succeed())

		GinkgoWriter.Printf("DPUServices auto-recreated and Ready\n")
	})

	// ── Post-recovery assertions ──────────────────────────────────────────────

	It("should have DPUDeployment return to Ready after all child objects recovered", func() {
		Eventually(func(g Gomega) {
			dpuDeployment := getDPUDeployment()
			g.Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
				"DPUDeployment should be Ready after child object recovery")
		}).WithTimeout(5*time.Minute).WithPolling(10*time.Second).Should(Succeed())
	})

	It("should have all DPUs remain Ready — no reprovisioning triggered", func() {
		expectedDPUs := len(dpuHostWorkers)
		dpuList := &provisioningv1.DPUList{}
		Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())

		readyCount := 0
		for _, dpu := range dpuList.Items {
			if dpu.Status.Phase == provisioningv1.DPUReady {
				readyCount++
			}
		}
		Expect(readyCount).To(BeNumerically(">=", expectedDPUs),
			"DPUs should remain Ready after child object recovery — got %d Ready (expected %d)",
			readyCount, expectedDPUs)
	})

	It("should have DPU worker nodes Ready in the hosted cluster after recovery", func() {
		expectedNodes := len(dpuHostWorkers)

		// Nodes may be temporarily SchedulingDisabled after HBN deletion —
		// wait for them to return to Ready.
		Eventually(func(g Gomega) {
			readyNodes, err := utils.GetReadyWorkerNodes(ctx, hostedClient)
			g.Expect(err).NotTo(HaveOccurred())
			g.Expect(len(readyNodes)).To(BeNumerically(">=", expectedNodes),
				"expected at least %d Ready worker nodes, got %d", expectedNodes, len(readyNodes))
		}).WithTimeout(10*time.Minute).WithPolling(30*time.Second).Should(Succeed())
	})

	It("should have a healthy cluster after child object recovery", func() {
		waitForClusterHealth()
	})
})
