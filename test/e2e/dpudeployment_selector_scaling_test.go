package e2e

import (
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

// TC-DPUD-006: A DPUDeployment Can Scale DPUs Up and Down Based on Selectors Updates
//
// Validates that removing the feature.node.kubernetes.io/dpu-enabled label from a
// DPUNode causes the DPUSet selector to stop matching, triggering a scale-down
// (Node Effect → OS Installing), and that restoring the label triggers a scale-up
// (re-provision → DPUReady).
var _ = Describe("TC-DPUD-006: A DPUDeployment Can Scale DPUs Up and Down Based on Selectors Updates",
	Label("dpudeployment-lifecycle", "dpudeployment-selector-scaling"), Ordered, func() {

		// labeledNodeNames collects the names of DPUNodes from which the dpu-enabled
		// label was removed, so AfterAll can restore them regardless of test outcome.
		var labeledNodeNames []string
		// affectedDPUNames records the DPU names present before label removal so that
		// scale-down and scale-up assertions target the exact objects under test rather
		// than relying on namespace-wide counts.
		var affectedDPUNames []string

		BeforeAll(func() {
			if dpfInput.NumberOfDPUNodes == 0 {
				Skip("No DPU nodes available, skipping TC-DPUD-006")
			}
		})

		// AfterAll fails the suite when a label patch errors, and waits
		// for the DPUDeployment and all DPUs in the namespace to reach Ready so the
		// cluster is verifiably healthy before the next test runs.
		AfterAll(func() {
			if len(labeledNodeNames) == 0 {
				return
			}

			By("AfterAll: restoring dpu-enabled label on affected DPUNodes")
			for _, nodeName := range labeledNodeNames {
				dpuNode := &provisioningv1.DPUNode{}
				Expect(mgmtClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      nodeName,
				}, dpuNode)).To(Succeed(), "AfterAll: failed to get DPUNode %s", nodeName)

				if _, ok := dpuNode.Labels[utils.DPUEnabledLabel]; ok {
					GinkgoWriter.Printf("AfterAll: DPUNode %s already has %s label\n",
						nodeName, utils.DPUEnabledLabel)
					continue
				}
				patch := client.MergeFrom(dpuNode.DeepCopy())
				if dpuNode.Labels == nil {
					dpuNode.Labels = make(map[string]string)
				}
				dpuNode.Labels[utils.DPUEnabledLabel] = ""
				Expect(mgmtClient.Patch(ctx, dpuNode, patch)).To(Succeed(),
					"AfterAll: failed to restore %s on DPUNode %s", utils.DPUEnabledLabel, nodeName)
				GinkgoWriter.Printf("AfterAll: restored %s label on DPUNode %s\n",
					utils.DPUEnabledLabel, nodeName)
			}

			By("AfterAll: waiting for DPUDeployment to return to Ready")
			Eventually(func(g Gomega) {
				g.Expect(isReady(getDPUDeployment().Status.Conditions)).To(BeTrue(),
					"AfterAll: DPUDeployment should be Ready after label restoration")
			}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

			By("AfterAll: waiting for all DPUs in namespace to return to Ready")
			Eventually(func(g Gomega) {
				dpuList := &provisioningv1.DPUList{}
				g.Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())
				for _, dpu := range dpuList.Items {
					g.Expect(dpu.Status.Phase).To(Equal(provisioningv1.DPUReady),
						"AfterAll: DPU %s should be Ready, got %s", dpu.Name, dpu.Status.Phase)
				}
			}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())
		})

		It("pre-condition: should have DPUDeployment in Ready state before selector scaling test", func() {
			dpuDeployment := getDPUDeployment()
			Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
				"DPUDeployment must be Ready before selector scaling test")
		})

		It("pre-condition: should have all DPUs in Ready phase before scale-down", func() {
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
				"expected at least %d DPUs Ready before scale-down, got %d", expectedDPUs, readyCount)
		})

		// ── Scale down ─────────────────────────────────────────────────────────────

		It("should trigger scale-down by removing the dpu-enabled label from DPUNodes", func() {
			dpuNodeList := &provisioningv1.DPUNodeList{}
			Expect(mgmtClient.List(ctx, dpuNodeList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())

			var nodesWithLabel []provisioningv1.DPUNode
			for _, n := range dpuNodeList.Items {
				if _, ok := n.Labels[utils.DPUEnabledLabel]; ok {
					nodesWithLabel = append(nodesWithLabel, n)
					labeledNodeNames = append(labeledNodeNames, n.Name)
				}
			}
			Expect(nodesWithLabel).NotTo(BeEmpty(),
				"no DPUNodes with label %s found in namespace %s", utils.DPUEnabledLabel, cfg.DPFNamespace)

			// record the exact DPU names that exist before label removal so
			// subsequent checks assert against those specific objects, not a namespace-wide count.
			dpuList := &provisioningv1.DPUList{}
			Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())
			Expect(dpuList.Items).NotTo(BeEmpty(), "no DPUs found before scale-down")
			for _, dpu := range dpuList.Items {
				affectedDPUNames = append(affectedDPUNames, dpu.Name)
			}

			By("Removing the dpu-enabled label from all matching DPUNodes")
			for i := range nodesWithLabel {
				n := &nodesWithLabel[i]
				patch := client.MergeFrom(n.DeepCopy())
				delete(n.Labels, utils.DPUEnabledLabel)
				Expect(mgmtClient.Patch(ctx, n, patch)).To(Succeed(),
					"failed to remove label from DPUNode %s", n.Name)
				GinkgoWriter.Printf("Removed %s label from DPUNode %s\n", utils.DPUEnabledLabel, n.Name)
			}

			By("Waiting for DPUDeployment to leave Ready state")
			Eventually(func(g Gomega) {
				dpuDeployment := getDPUDeployment()
				g.Expect(isReady(dpuDeployment.Status.Conditions)).To(BeFalse(),
					"DPUDeployment should leave Ready state after dpu-enabled label removal")
			}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

			// assert each specific recorded DPU left DPUReady.
			// A NotFound result is also accepted:
			// the DPUSet controller may delete the DPU CR (deleteStaleDPUs) before the
			// re-provision cycle recreates it.
			By("Waiting for each affected DPU to leave DPUReady phase")
			Eventually(func(g Gomega) {
				for _, dpuName := range affectedDPUNames {
					dpu := &provisioningv1.DPU{}
					err := mgmtClient.Get(ctx, client.ObjectKey{
						Namespace: cfg.DPFNamespace,
						Name:      dpuName,
					}, dpu)
					if apierrors.IsNotFound(err) {
						// Deleted by deleteStaleDPUs — counts as having left Ready.
						GinkgoWriter.Printf("DPU %s was deleted (scale-down)\n", dpuName)
						continue
					}
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(dpu.Status.Phase).NotTo(Equal(provisioningv1.DPUReady),
						"DPU %s should have left DPUReady phase, got %s", dpuName, dpu.Status.Phase)
					GinkgoWriter.Printf("DPU %s phase: %s\n", dpuName, dpu.Status.Phase)
				}
			}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

			GinkgoWriter.Printf("Scale-down triggered: DPUs entering deprovisioning cycle\n")
		})

		// ── Scale up ───────────────────────────────────────────────────────────────

		// In host-trusted mode the DPUNode controller re-adds the label automatically
		// (it merges k8s Node labels → DPUNode on every reconcile, and the k8s Node
		// label is kept by NFD's NodeFeatureRule). In zero-trust/Redfish mode there is
		// no such sync, so we restore the label explicitly to make the test work in
		// both deployment modes. In host-trusted deployments this patch is a no-op.
		It("should trigger scale-up by restoring the dpu-enabled label on DPUNodes", func() {
			By("Re-fetching DPUNodes and restoring the dpu-enabled label")
			for _, nodeName := range labeledNodeNames {
				dpuNode := &provisioningv1.DPUNode{}
				Expect(mgmtClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      nodeName,
				}, dpuNode)).To(Succeed(), "failed to get DPUNode %s", nodeName)

				if _, ok := dpuNode.Labels[utils.DPUEnabledLabel]; ok {
					GinkgoWriter.Printf("DPUNode %s already has %s label (NFD re-added it)\n",
						nodeName, utils.DPUEnabledLabel)
					continue
				}

				patch := client.MergeFrom(dpuNode.DeepCopy())
				if dpuNode.Labels == nil {
					dpuNode.Labels = make(map[string]string)
				}
				dpuNode.Labels[utils.DPUEnabledLabel] = ""
				Expect(mgmtClient.Patch(ctx, dpuNode, patch)).To(Succeed(),
					"failed to restore label on DPUNode %s", nodeName)
				GinkgoWriter.Printf("Restored %s label on DPUNode %s\n", utils.DPUEnabledLabel, nodeName)
			}
		})

		// assert each specific recorded DPU returned to DPUReady
		// DPUs may have been deleted and recreated
		// with the same name (derived from the stable DPUDevice name), so Get by name
		// remains valid after the reprovision cycle.
		It("should have all DPUs return to Ready phase after scale-up", func() {
			Eventually(func(g Gomega) {
				for _, dpuName := range affectedDPUNames {
					dpu := &provisioningv1.DPU{}
					g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
						Namespace: cfg.DPFNamespace,
						Name:      dpuName,
					}, dpu)).To(Succeed(), "DPU %s not found after scale-up", dpuName)
					g.Expect(dpu.Status.Phase).To(Equal(provisioningv1.DPUReady),
						"DPU %s should return to DPUReady after scale-up, got %s",
						dpuName, dpu.Status.Phase)
				}
			}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

			GinkgoWriter.Printf("All affected DPUs returned to DPUReady phase after scale-up\n")
		})

		It("should have DPUDeployment return to Ready state after scale-up", func() {
			Eventually(func(g Gomega) {
				dpuDeployment := getDPUDeployment()
				g.Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
					"DPUDeployment should return to Ready state after label restoration")
			}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())
		})

		// ── Post-scaling assertions ─────────────────────────────────────────────────

		It("should have DPU worker nodes Ready in the hosted cluster after scale-up", func() {
			expectedNodes := len(dpuHostWorkers)
			Eventually(func(g Gomega) {
				readyNodes, err := utils.GetReadyWorkerNodes(ctx, hostedClient)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(len(readyNodes)).To(BeNumerically(">=", expectedNodes),
					"expected at least %d Ready worker nodes in hosted cluster, got %d",
					expectedNodes, len(readyNodes))
			}).WithTimeout(10 * time.Minute).WithPolling(30 * time.Second).Should(Succeed())
		})

		It("should have a healthy cluster after selector-based scaling", func() {
			waitForClusterHealth()
		})
	})
