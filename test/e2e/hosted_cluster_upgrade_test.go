package e2e

import (
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

var dpfHCPProvisionerGVR = schema.GroupVersionResource{
	Group:    "provisioning.dpu.hcp.io",
	Version:  "v1alpha1",
	Resource: "dpfhcpprovisioners",
}

var _ = Describe("Hosted Cluster Upgrade", Label("hosted-upgrade"), Ordered, func() {
	var (
		originalReleaseImage string
		originalBFBName      string
		newBFBName           string
	)

	BeforeAll(func() {
		if cfg.UpgradeReleaseImage == "" {
			Skip("--upgrade-release-image not provided, skipping hosted cluster upgrade test")
		}
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available")
		}
	})

	It("should record the current release image from DPFHCPProvisioner", func() {
		provisioner := &unstructured.Unstructured{}
		provisioner.SetGroupVersionKind(schema.GroupVersionKind{
			Group:   "provisioning.dpu.hcp.io",
			Version: "v1alpha1",
			Kind:    "DPFHCPProvisioner",
		})

		Expect(mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: cfg.ClustersNamespace,
			Name:      cfg.HostedClusterName,
		}, provisioner)).To(Succeed(), "failed to get DPFHCPProvisioner")

		var found bool
		originalReleaseImage, found, _ = unstructured.NestedString(provisioner.Object, "spec", "ocpReleaseImage")
		Expect(found).To(BeTrue(), "DPFHCPProvisioner missing spec.ocpReleaseImage")
		GinkgoWriter.Printf("Current release image: %s\n", originalReleaseImage)
		GinkgoWriter.Printf("Target release image: %s\n", cfg.UpgradeReleaseImage)

		Expect(cfg.UpgradeReleaseImage).NotTo(Equal(originalReleaseImage),
			"upgrade release image must differ from current")
	})

	It("should update the release image in DPFHCPProvisioner", func() {
		provisioner := &unstructured.Unstructured{}
		provisioner.SetGroupVersionKind(schema.GroupVersionKind{
			Group:   "provisioning.dpu.hcp.io",
			Version: "v1alpha1",
			Kind:    "DPFHCPProvisioner",
		})

		Expect(mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: cfg.ClustersNamespace,
			Name:      cfg.HostedClusterName,
		}, provisioner)).To(Succeed())

		Expect(unstructured.SetNestedField(provisioner.Object, cfg.UpgradeReleaseImage,
			"spec", "ocpReleaseImage")).To(Succeed())
		Expect(mgmtClient.Update(ctx, provisioner)).To(Succeed(),
			"failed to update DPFHCPProvisioner release image")
		GinkgoWriter.Printf("Updated DPFHCPProvisioner to release image: %s\n", cfg.UpgradeReleaseImage)
	})

	It("should transition DPFHCPProvisioner through Upgrading to Ready", func() {
		By("Waiting for DPFHCPProvisioner to enter Upgrading phase")
		Eventually(func(g Gomega) {
			phase := getDPFHCPProvisionerPhase()
			g.Expect(phase).To(Equal("Upgrading"),
				"Expected Upgrading phase, got %s", phase)
		}).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		By("Waiting for DPFHCPProvisioner to return to Ready phase")
		Eventually(func(g Gomega) {
			phase := getDPFHCPProvisionerPhase()
			g.Expect(phase).To(Equal("Ready"),
				"Expected Ready phase after upgrade, got %s", phase)
		}).WithTimeout(60 * time.Minute).WithPolling(30 * time.Second).Should(Succeed())

		GinkgoWriter.Println("DPFHCPProvisioner upgrade complete — phase is Ready")
	})

	It("should record current BFB and create a new BFB with different filename", func() {
		By("Reading current BFB from DPUDeployment")
		dpuDeployment := getDPUDeployment()
		Expect(dpuDeployment.Spec.DPUs.BFB).NotTo(BeNil(), "DPUDeployment has no BFB reference")
		originalBFBName = *dpuDeployment.Spec.DPUs.BFB
		GinkgoWriter.Printf("Current BFB: %s\n", originalBFBName)

		By("Reading current BFB object")
		currentBFB := &provisioningv1.BFB{}
		Expect(mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: cfg.DPFNamespace,
			Name:      originalBFBName,
		}, currentBFB)).To(Succeed())

		By("Creating new BFB object with updated filename")
		newBFBName = fmt.Sprintf("%s-upgraded", originalBFBName)
		newFileName := fmt.Sprintf("upgraded-%s", ptr.Deref(currentBFB.Spec.FileName, "bf-bundle.bfb"))

		newBFB := &provisioningv1.BFB{
			ObjectMeta: metav1.ObjectMeta{
				Namespace: cfg.DPFNamespace,
				Name:      newBFBName,
			},
			Spec: provisioningv1.BFBSpec{
				URL:      currentBFB.Spec.URL,
				FileName: &newFileName,
			},
		}
		if currentBFB.Spec.Versions != nil {
			newBFB.Spec.Versions = currentBFB.Spec.Versions.DeepCopy()
		}

		Expect(mgmtClient.Create(ctx, newBFB)).To(Succeed(),
			"failed to create new BFB %s", newBFBName)
		GinkgoWriter.Printf("Created new BFB: %s (filename=%s)\n", newBFBName, newFileName)
	})

	It("should update DPUDeployment to reference the new BFB", func() {
		dpuDeployment := getDPUDeployment()
		dpuDeployment.Spec.DPUs.BFB = &newBFBName
		Expect(mgmtClient.Update(ctx, dpuDeployment)).To(Succeed(),
			"failed to update DPUDeployment BFB reference")
		GinkgoWriter.Printf("Updated DPUDeployment BFB reference to: %s\n", newBFBName)
	})

	It("should wait for all DPUs to be reprovisioned and reach Ready", func() {
		expectedDPUs := len(dpuHostWorkers)
		By(fmt.Sprintf("Waiting for %d DPU objects to be reprovisioned (non-Ready during rollout)", expectedDPUs))

		// First wait for at least one DPU to leave Ready (reprovisioning started)
		Eventually(func(g Gomega) {
			dpuList := &provisioningv1.DPUList{}
			g.Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())
			notReady := 0
			for _, dpu := range dpuList.Items {
				if dpu.Status.Phase != provisioningv1.DPUReady {
					notReady++
				}
			}
			g.Expect(notReady).To(BeNumerically(">", 0),
				"Expected at least one DPU to leave Ready phase during reprovisioning")
		}).WithTimeout(10 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

		By(fmt.Sprintf("Waiting for all %d DPUs to return to Ready phase", expectedDPUs))
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
				"Expected %d DPUs Ready, got %d", expectedDPUs, readyCount)
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("All %d DPUs reprovisioned and Ready\n", expectedDPUs)
	})

	It("should have DPU worker nodes Ready in hosted cluster after upgrade", func() {
		expectedNodes := len(dpuHostWorkers)
		Eventually(func(g Gomega) {
			readyNodes, err := utils.GetReadyWorkerNodes(ctx, hostedClient)
			g.Expect(err).NotTo(HaveOccurred())
			g.Expect(len(readyNodes)).To(BeNumerically(">=", expectedNodes),
				"Expected at least %d Ready DPU worker nodes, got %d", expectedNodes, len(readyNodes))
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("All %d DPU worker nodes Ready after upgrade\n", expectedNodes)
	})

	It("should have a healthy cluster after hosted cluster upgrade", func() {
		By("Verifying cluster operators are healthy on management cluster")
		checkClusterOperatorsHealthy(mgmtClient, "management")

		By("Verifying cluster operators are healthy on hosted cluster")
		checkClusterOperatorsHealthy(hostedClient, "hosted")

		By("Verifying all pods on DPU worker nodes are Running")
		checkPodsHealthyOnNodes(mgmtClient, dpuHostWorkers)
	})

	// Cleanup: remove the new BFB object (DPUDeployment still points to it which is fine)
	AfterAll(func() {
		if newBFBName != "" {
			GinkgoWriter.Printf("Note: new BFB %s left in cluster (DPUDeployment references it)\n", newBFBName)
		}
	})
})

func getDPFHCPProvisionerPhase() string {
	provisioner := &unstructured.Unstructured{}
	provisioner.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "provisioning.dpu.hcp.io",
		Version: "v1alpha1",
		Kind:    "DPFHCPProvisioner",
	})
	err := mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.ClustersNamespace,
		Name:      cfg.HostedClusterName,
	}, provisioner)
	Expect(err).NotTo(HaveOccurred(), "failed to get DPFHCPProvisioner")

	phase, _, _ := unstructured.NestedString(provisioner.Object, "status", "phase")
	return phase
}

func getDPUDeployment() *dpuservicev1.DPUDeployment {
	dpuDeployment := &dpuservicev1.DPUDeployment{}
	Expect(mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.DPFNamespace,
		Name:      cfg.DPUDeploymentName,
	}, dpuDeployment)).To(Succeed(), "failed to get DPUDeployment")
	return dpuDeployment
}
