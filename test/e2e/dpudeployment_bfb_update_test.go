package e2e

import (
	"fmt"
	"path"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

// newBFBFileName returns the filename for the new BFB: the explicit flag value
// if set, otherwise the last segment of the URL.
func newBFBFileName() string {
	if cfg.NewBFBFileName != "" {
		return cfg.NewBFBFileName
	}
	return path.Base(cfg.NewBFBURL)
}

// TC-DPUD-002: Change BFB in DPUDeployment
//
// Creates a new BFB object, updates the DPUDeployment to reference it, then
// validates that the change propagates through the reconciliation chain:
//
//	DPUDeployment → DPUSets → DPU reprovisioning → hosted cluster nodes Ready
//
// The old (orphaned) BFB is deleted in AfterAll. The cluster is intentionally
// left at the new BFB — restoring would require another full reprovision cycle.
var _ = Describe("TC-DPUD-002: DPUDeployment Update - Change BFB", Label("dpudeployment-lifecycle", "dpudeployment-bfb-update"), Ordered, func() {
	var (
		originalBFBName string
		newBFBName      string
	)

	BeforeAll(func() {
		if cfg.NewBFBURL == "" {
			Skip("--new-bfb-url not provided, skipping TC-DPUD-002")
		}
		if cfg.NewBFBVersionsBSP == "" || cfg.NewBFBVersionsDOCA == "" ||
			cfg.NewBFBVersionsUEFI == "" || cfg.NewBFBVersionsATF == "" {
			Skip("--new-bfb-bsp/doca/uefi/atf not provided, skipping TC-DPUD-002")
		}
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available, skipping TC-DPUD-002")
		}
	})

	It("should have DPUDeployment in Ready state with a valid BFB reference", func() {
		dpuDeployment := getDPUDeployment()
		Expect(dpuDeployment.Spec.DPUs.BFB).NotTo(BeNil(), "DPUDeployment has no BFB reference")

		ready := false
		for _, cond := range dpuDeployment.Status.Conditions {
			if cond.Type == "Ready" && cond.Status == metav1.ConditionTrue {
				ready = true
				break
			}
		}
		Expect(ready).To(BeTrue(), "DPUDeployment must be Ready before BFB update")

		originalBFBName = *dpuDeployment.Spec.DPUs.BFB
		newBFBName = fmt.Sprintf("%s-updated", originalBFBName)
		GinkgoWriter.Printf("DPUDeployment %s is Ready, current BFB: %s, new BFB will be: %s\n",
			cfg.DPUDeploymentName, originalBFBName, newBFBName)
	})

	It("should have all DPU objects in Ready phase before BFB update", func() {
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
			"expected at least %d DPUs Ready before BFB update, got %d (total: %d)",
			expectedDPUs, readyCount, len(dpuList.Items))

		GinkgoWriter.Printf("Pre-update: %d/%d DPUs Ready\n", readyCount, expectedDPUs)
	})

	It("should create the new BFB object with versions set", func() {
		fileName := newBFBFileName()

		GinkgoWriter.Printf("Creating BFB %s (url=%s filename=%s bsp=%s doca=%s)\n",
			newBFBName, cfg.NewBFBURL, fileName,
			cfg.NewBFBVersionsBSP, cfg.NewBFBVersionsDOCA)

		newBFB := &provisioningv1.BFB{
			ObjectMeta: metav1.ObjectMeta{
				Namespace: cfg.DPFNamespace,
				Name:      newBFBName,
			},
			Spec: provisioningv1.BFBSpec{
				URL:      cfg.NewBFBURL,
				FileName: ptr.To(fileName),
				Versions: &provisioningv1.BFBVersions{
					BSP:  cfg.NewBFBVersionsBSP,
					DOCA: cfg.NewBFBVersionsDOCA,
					UEFI: cfg.NewBFBVersionsUEFI,
					ATF:  cfg.NewBFBVersionsATF,
				},
			},
		}
		Expect(mgmtClient.Create(ctx, newBFB)).To(Succeed(),
			"failed to create BFB %s", newBFBName)
	})

	It("should have the new BFB reach Ready phase", func() {
		Eventually(func(g Gomega) {
			bfb := &provisioningv1.BFB{}
			g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      newBFBName,
			}, bfb)).To(Succeed())
			g.Expect(bfb.Status.Phase).To(Equal(provisioningv1.BFBReady),
				"BFB %s phase is %s, want Ready", newBFBName, bfb.Status.Phase)
		}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("BFB %s is Ready\n", newBFBName)
	})

	It("should update DPUDeployment to reference the new BFB", func() {
		dpuDeployment := getDPUDeployment()
		dpuDeployment.Spec.DPUs.BFB = ptr.To(newBFBName)
		Expect(mgmtClient.Update(ctx, dpuDeployment)).To(Succeed(),
			"failed to update DPUDeployment BFB reference to %s", newBFBName)

		GinkgoWriter.Printf("Updated DPUDeployment %s: BFB %s → %s\n",
			cfg.DPUDeploymentName, originalBFBName, newBFBName)
	})

	It("should propagate the new BFB reference to all DPUSets", func() {
		Eventually(func(g Gomega) {
			dpuSetList := &provisioningv1.DPUSetList{}
			g.Expect(mgmtClient.List(ctx, dpuSetList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())
			g.Expect(dpuSetList.Items).NotTo(BeEmpty(), "expected at least one DPUSet")

			for _, dpuSet := range dpuSetList.Items {
				g.Expect(dpuSet.Spec.DPUTemplate.Spec.BFB).NotTo(BeNil(),
					"DPUSet %s has no BFB reference", dpuSet.Name)
				g.Expect(dpuSet.Spec.DPUTemplate.Spec.BFB.Name).To(Equal(newBFBName),
					"DPUSet %s BFB should be %s, got %s",
					dpuSet.Name, newBFBName, dpuSet.Spec.DPUTemplate.Spec.BFB.Name)
			}

			GinkgoWriter.Printf("All %d DPUSet(s) reference new BFB %s\n",
				len(dpuSetList.Items), newBFBName)
		}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())
	})

	It("should delete DPU objects to trigger reprovisioning with the new BFB", func() {
		dpuList := &provisioningv1.DPUList{}
		Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())
		Expect(dpuList.Items).NotTo(BeEmpty(), "no DPU objects found")

		for i := range dpuList.Items {
			dpu := &dpuList.Items[i]
			Expect(mgmtClient.Delete(ctx, dpu)).To(Succeed(),
				"failed to delete DPU %s", dpu.Name)
			GinkgoWriter.Printf("Deleted DPU %s to trigger reprovisioning\n", dpu.Name)
		}

		By("Waiting for at least one DPU to leave Ready phase")
		Eventually(func(g Gomega) {
			dl := &provisioningv1.DPUList{}
			g.Expect(mgmtClient.List(ctx, dl, client.InNamespace(cfg.DPFNamespace))).To(Succeed())
			notReady := 0
			for _, dpu := range dl.Items {
				if dpu.Status.Phase != provisioningv1.DPUReady {
					notReady++
				}
			}
			g.Expect(notReady).To(BeNumerically(">", 0),
				"expected at least one DPU to be reprovisioning")
		}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

		GinkgoWriter.Println("Reprovisioning started")
	})

	It("should reprovision all DPUs and return to Ready phase", func() {
		expectedDPUs := len(dpuHostWorkers)

		Eventually(func(g Gomega) {
			dpuList := &provisioningv1.DPUList{}
			g.Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())
			g.Expect(len(dpuList.Items)).To(BeNumerically(">=", expectedDPUs))

			readyCount := 0
			for _, dpu := range dpuList.Items {
				if dpu.Status.Phase == provisioningv1.DPUReady {
					readyCount++
				}
			}
			g.Expect(readyCount).To(BeNumerically(">=", expectedDPUs),
				"expected %d DPUs Ready, got %d (total: %d)",
				expectedDPUs, readyCount, len(dpuList.Items))
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("All %d DPUs reprovisioned and Ready with BFB %s\n", expectedDPUs, newBFBName)
	})

	It("should have DPU worker nodes Ready in the hosted cluster", func() {
		expectedNodes := len(dpuHostWorkers)

		Eventually(func(g Gomega) {
			readyNodes, err := utils.GetReadyWorkerNodes(ctx, hostedClient)
			g.Expect(err).NotTo(HaveOccurred())
			g.Expect(len(readyNodes)).To(BeNumerically(">=", expectedNodes),
				"expected at least %d Ready DPU worker nodes, got %d", expectedNodes, len(readyNodes))
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("All %d DPU worker nodes Ready in hosted cluster\n", expectedNodes)
	})

	It("should have a healthy cluster after BFB update", func() {
		By("Waiting for cluster operators to be healthy on management cluster")
		Eventually(func() []string {
			return InterceptGomegaFailures(func() {
				checkClusterOperatorsHealthy(mgmtClient, "management")
			})
		}).WithTimeout(15 * time.Minute).WithPolling(30 * time.Second).Should(BeEmpty())

		By("Waiting for cluster operators to be healthy on hosted cluster")
		Eventually(func() []string {
			return InterceptGomegaFailures(func() {
				checkClusterOperatorsHealthy(hostedClient, "hosted")
			})
		}).WithTimeout(15 * time.Minute).WithPolling(30 * time.Second).Should(BeEmpty())

		By("Verifying all pods on DPU worker nodes are Running")
		checkPodsHealthyOnNodes(mgmtClient, dpuHostWorkers)
	})

	AfterAll(func() {
		if originalBFBName == "" || newBFBName == "" {
			return
		}

		dpuDeployment := getDPUDeployment()
		dpuDeploymentUpdated := dpuDeployment.Spec.DPUs.BFB != nil &&
			*dpuDeployment.Spec.DPUs.BFB == newBFBName

		if dpuDeploymentUpdated {
			// Test succeeded: DPUDeployment now references the new BFB.
			// The old BFB is orphaned — delete it.
			oldBFB := &provisioningv1.BFB{}
			err := mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      originalBFBName,
			}, oldBFB)
			if err == nil {
				Expect(mgmtClient.Delete(ctx, oldBFB)).To(Succeed())
				GinkgoWriter.Printf("AfterAll: deleted orphaned old BFB %s\n", originalBFBName)
			}
		} else {
			// Test failed before DPUDeployment was updated.
			// The new BFB is orphaned — delete it.
			newBFB := &provisioningv1.BFB{}
			err := mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      newBFBName,
			}, newBFB)
			if err == nil {
				Expect(mgmtClient.Delete(ctx, newBFB)).To(Succeed())
				GinkgoWriter.Printf("AfterAll: deleted orphaned new BFB %s (test did not complete)\n", newBFBName)
			}
		}
	})
})
