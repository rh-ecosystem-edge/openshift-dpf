package e2e

import (
	"fmt"
	"os/exec"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

const ignitionReleaseAnnotation = "dpfhcpprovisioner.dpu.hcp.io/bfcfg-template-ocp-release-image"

var _ = Describe("Hosted Cluster Upgrade", Label("hosted-upgrade"), Ordered, func() {
	var (
		originalReleaseImage string
		originalBFBName      string
		newBFBName           string
		dpuDeploymentGen     int64
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
		provisioner := getDPFHCPProvisioner()

		var found bool
		originalReleaseImage, found, _ = unstructured.NestedString(provisioner.Object, "spec", "ocpReleaseImage")
		Expect(found).To(BeTrue(), "DPFHCPProvisioner missing spec.ocpReleaseImage")
		GinkgoWriter.Printf("Current release image: %s\n", originalReleaseImage)
		GinkgoWriter.Printf("Target release image: %s\n", cfg.UpgradeReleaseImage)

		Expect(cfg.UpgradeReleaseImage).NotTo(Equal(originalReleaseImage),
			"upgrade release image must differ from current")
	})

	It("should verify the target release image exists", func() {
		By(fmt.Sprintf("Running oc adm release info for %s", cfg.UpgradeReleaseImage))
		cmd := exec.CommandContext(ctx, "oc", "adm", "release", "info", cfg.UpgradeReleaseImage,
			"-o", "jsonpath={.digest}")
		output, err := cmd.CombinedOutput()
		Expect(err).NotTo(HaveOccurred(),
			"target release image %s not found or inaccessible: %s", cfg.UpgradeReleaseImage, string(output))
		GinkgoWriter.Printf("Target image verified, digest: %s\n", string(output))
	})

	It("should handle machineOSURL before upgrade", func() {
		provisioner := getDPFHCPProvisioner()

		currentURL, _, _ := unstructured.NestedString(provisioner.Object, "spec", "machineOSURL")
		if currentURL == "" && cfg.UpgradeMachineOSURL == "" {
			GinkgoWriter.Println("machineOSURL not set, nothing to do")
			return
		}

		if currentURL != "" && cfg.UpgradeMachineOSURL == "" {
			GinkgoWriter.Println("WARNING: machineOSURL is set on DPFHCPProvisioner but " +
				"--upgrade-machine-os-url was not provided. The operator will continue using " +
				"the existing value. Set --upgrade-machine-os-url to update it, or 'remove' " +
				"to clear it (operator will auto-resolve).")
			return
		}

		if cfg.UpgradeMachineOSURL == "remove" {
			By("Removing machineOSURL from DPFHCPProvisioner")
			unstructured.RemoveNestedField(provisioner.Object, "spec", "machineOSURL")
		} else {
			By("Updating machineOSURL on DPFHCPProvisioner")
			Expect(unstructured.SetNestedField(provisioner.Object, cfg.UpgradeMachineOSURL,
				"spec", "machineOSURL")).To(Succeed())
		}
		Expect(mgmtClient.Update(ctx, provisioner)).To(Succeed(),
			"failed to update machineOSURL on DPFHCPProvisioner")
		GinkgoWriter.Printf("machineOSURL handled (action=%s)\n", cfg.UpgradeMachineOSURL)
	})

	It("should update the release image in DPFHCPProvisioner", func() {
		provisioner := getDPFHCPProvisioner()

		Expect(unstructured.SetNestedField(provisioner.Object, cfg.UpgradeReleaseImage,
			"spec", "ocpReleaseImage")).To(Succeed())
		Expect(mgmtClient.Update(ctx, provisioner)).To(Succeed(),
			"failed to update DPFHCPProvisioner release image")
		GinkgoWriter.Printf("Updated DPFHCPProvisioner to release image: %s\n", cfg.UpgradeReleaseImage)
	})

	It("should verify the ignition ConfigMap is deleted during upgrade", func() {
		cmName := ignitionConfigMapName()

		By("Waiting for DPFHCPProvisioner to leave Ready phase")
		Eventually(func(g Gomega) {
			phase := getDPFHCPProvisionerPhase()
			g.Expect(phase).NotTo(Equal("Ready"),
				"DPFHCPProvisioner still in Ready phase")
			g.Expect(phase).NotTo(Equal("Failed"),
				"DPFHCPProvisioner entered Failed phase before upgrading")
		}).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		By(fmt.Sprintf("Waiting for ignition ConfigMap %s to be deleted", cmName))
		Eventually(func(g Gomega) {
			cm := &corev1.ConfigMap{}
			err := mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      cmName,
			}, cm)
			g.Expect(apierrors.IsNotFound(err)).To(BeTrue(),
				"ignition ConfigMap %s should be deleted during upgrade, got: %v", cmName, err)
		}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("Ignition ConfigMap %s cleaned up during upgrade\n", cmName)
	})

	It("should transition DPFHCPProvisioner back to Ready after upgrade", func() {
		By("Waiting for DPFHCPProvisioner to reach Ready phase")
		Eventually(func(g Gomega) {
			phase := getDPFHCPProvisionerPhase()
			g.Expect(phase).NotTo(Equal("Failed"),
				"DPFHCPProvisioner entered Failed phase during upgrade")
			g.Expect(phase).To(Equal("Ready"),
				"Expected Ready phase after upgrade, got %s", phase)
		}).WithTimeout(60 * time.Minute).WithPolling(30 * time.Second).Should(Succeed())

		GinkgoWriter.Println("DPFHCPProvisioner upgrade complete — phase is Ready")
	})

	It("should verify the ignition ConfigMap is recreated with correct release annotation", func() {
		cmName := ignitionConfigMapName()

		By(fmt.Sprintf("Waiting for ignition ConfigMap %s to be recreated", cmName))
		Eventually(func(g Gomega) {
			cm := &corev1.ConfigMap{}
			g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      cmName,
			}, cm)).To(Succeed(), "ignition ConfigMap %s not recreated after upgrade", cmName)

			actualImage := cm.Annotations[ignitionReleaseAnnotation]
			g.Expect(actualImage).NotTo(BeEmpty(),
				"ignition ConfigMap %s missing release image annotation", cmName)
			g.Expect(actualImage).To(Equal(cfg.UpgradeReleaseImage),
				"ignition ConfigMap release annotation mismatch: expected %s, got %s",
				cfg.UpgradeReleaseImage, actualImage)
		}).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("Ignition ConfigMap %s recreated with correct release image\n", cmName)
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

		By("Recording DPUDeployment generation before patch")
		dpuDeployment.Spec.DPUs.BFB = &newBFBName
		Expect(mgmtClient.Update(ctx, dpuDeployment)).To(Succeed(),
			"failed to update DPUDeployment BFB reference")

		dpuDeployment = getDPUDeployment()
		dpuDeploymentGen = dpuDeployment.Generation
		GinkgoWriter.Printf("Updated DPUDeployment BFB reference to: %s (generation=%d)\n",
			newBFBName, dpuDeploymentGen)
	})

	It("should wait for all DPUs to be reprovisioned and reach Ready", func() {
		expectedDPUs := len(dpuHostWorkers)

		By(fmt.Sprintf("Waiting for DPUDeployment to observe generation %d", dpuDeploymentGen))
		Eventually(func(g Gomega) {
			dpuDeployment := getDPUDeployment()
			g.Expect(dpuDeployment.Status.ObservedGeneration).To(Equal(dpuDeploymentGen),
				"DPUDeployment observedGeneration=%d, want %d",
				dpuDeployment.Status.ObservedGeneration, dpuDeploymentGen)
		}).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		By(fmt.Sprintf("Waiting for %d DPU objects to be reprovisioned (non-Ready during rollout)", expectedDPUs))
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
		waitForClusterHealth()
	})

	AfterAll(func() {
		if newBFBName != "" {
			GinkgoWriter.Printf("Note: new BFB %s left in cluster (DPUDeployment references it)\n", newBFBName)
		}
	})
})

func getDPFHCPProvisioner() *unstructured.Unstructured {
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
	return provisioner
}

func getDPFHCPProvisionerPhase() string {
	provisioner := getDPFHCPProvisioner()
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
