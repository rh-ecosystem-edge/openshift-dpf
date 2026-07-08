package e2e

import (
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	bfcfgTemplateLabel = "provisioning.dpu.nvidia.com/bfcfg-template"
)

// ignitionConfigMapName returns the expected ignition ConfigMap name for the DPU cluster.
func ignitionConfigMapName() string {
	return fmt.Sprintf("bfcfg-%s.cfg", cfg.DPUClusterName)
}

var _ = Describe("TC-DPUD-001: Delete and Recreate DPUDeployment", Label("dpudeployment-lifecycle"), Ordered, func() {
	var (
		dpuDeploymentBackup *dpuservicev1.DPUDeployment
	)

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available — skipping DPUDeployment lifecycle tests")
		}
	})

	It("should have a DPUDeployment in Ready state before deletion", func() {
		dpuDeployment := &dpuservicev1.DPUDeployment{}
		Expect(mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: cfg.DPFNamespace,
			Name:      cfg.DPUDeploymentName,
		}, dpuDeployment)).To(Succeed(), "DPUDeployment should exist before test")

		dpuDeploymentBackup = dpuDeployment.DeepCopy()
		GinkgoWriter.Printf("DPUDeployment %s/%s exists (generation=%d)\n",
			dpuDeployment.Namespace, dpuDeployment.Name, dpuDeployment.Generation)
	})

	It("should have an ignition ConfigMap before deletion", func() {
		cm := &corev1.ConfigMap{}
		cmName := ignitionConfigMapName()
		Expect(mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: cfg.DPFNamespace,
			Name:      cmName,
		}, cm)).To(Succeed(), "Ignition ConfigMap %s should exist before DPUDeployment deletion", cmName)

		Expect(cm.Labels).To(HaveKeyWithValue(bfcfgTemplateLabel, "true"),
			"ConfigMap should have the bfcfg-template label")
		GinkgoWriter.Printf("Ignition ConfigMap %s exists with bfcfg-template label\n", cmName)
	})

	It("should delete the DPUDeployment", func() {
		dpuDeployment := &dpuservicev1.DPUDeployment{
			ObjectMeta: metav1.ObjectMeta{
				Namespace: cfg.DPFNamespace,
				Name:      cfg.DPUDeploymentName,
			},
		}
		Expect(mgmtClient.Delete(ctx, dpuDeployment)).To(Succeed(),
			"Failed to delete DPUDeployment")

		By("Waiting for DPUDeployment to be fully removed")
		Eventually(func(g Gomega) {
			err := mgmtClient.Get(ctx, client.ObjectKeyFromObject(dpuDeployment), dpuDeployment)
			g.Expect(apierrors.IsNotFound(err)).To(BeTrue(),
				"DPUDeployment should be fully deleted, got: %v", err)
		}).WithTimeout(10 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("DPUDeployment %s deleted successfully\n", cfg.DPUDeploymentName)
	})

	It("should delete the ignition ConfigMap after DPUDeployment removal", func() {
		cmName := ignitionConfigMapName()
		By(fmt.Sprintf("Waiting for ignition ConfigMap %s to be deleted", cmName))

		Eventually(func(g Gomega) {
			cm := &corev1.ConfigMap{}
			err := mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      cmName,
			}, cm)
			g.Expect(apierrors.IsNotFound(err)).To(BeTrue(),
				"Ignition ConfigMap %s should be deleted after DPUDeployment removal, got: %v", cmName, err)
		}).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("Ignition ConfigMap %s deleted as expected\n", cmName)
	})

	It("should recreate the DPUDeployment", func() {
		Expect(dpuDeploymentBackup).NotTo(BeNil(), "DPUDeployment backup should have been captured")

		newDeployment := &dpuservicev1.DPUDeployment{
			ObjectMeta: metav1.ObjectMeta{
				Namespace:   dpuDeploymentBackup.Namespace,
				Name:        dpuDeploymentBackup.Name,
				Labels:      dpuDeploymentBackup.Labels,
				Annotations: dpuDeploymentBackup.Annotations,
			},
			Spec: dpuDeploymentBackup.Spec,
		}

		Expect(mgmtClient.Create(ctx, newDeployment)).To(Succeed(),
			"Failed to recreate DPUDeployment")
		GinkgoWriter.Printf("DPUDeployment %s recreated\n", newDeployment.Name)
	})

	It("should reach Ready state after recreation", func() {
		By("Waiting for DPUDeployment to become Ready")
		Eventually(func(g Gomega) {
			dpuDeployment := &dpuservicev1.DPUDeployment{}
			g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      cfg.DPUDeploymentName,
			}, dpuDeployment)).To(Succeed())

			ready := false
			for _, cond := range dpuDeployment.Status.Conditions {
				if cond.Type == "Ready" && cond.Status == metav1.ConditionTrue {
					ready = true
					break
				}
			}
			g.Expect(ready).To(BeTrue(), "DPUDeployment should have Ready=True condition")
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(5 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("DPUDeployment %s is Ready\n", cfg.DPUDeploymentName)
	})

	It("should recreate the ignition ConfigMap after DPUDeployment recreation", func() {
		cmName := ignitionConfigMapName()
		By(fmt.Sprintf("Waiting for ignition ConfigMap %s to be recreated", cmName))

		Eventually(func(g Gomega) {
			cm := &corev1.ConfigMap{}
			g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      cmName,
			}, cm)).To(Succeed(), "Ignition ConfigMap should be recreated")

			g.Expect(cm.Labels).To(HaveKeyWithValue(bfcfgTemplateLabel, "true"),
				"Recreated ConfigMap should have bfcfg-template label")
		}).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("Ignition ConfigMap %s recreated successfully\n", cmName)
	})
})
