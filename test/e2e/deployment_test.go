package e2e

import (
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

var _ = Describe("Deployment Verification", Label("deployment"), Ordered, func() {

	It("should have all worker nodes Ready in management cluster", func() {
		if cfg.WorkerCount == 0 {
			Skip("WORKER_COUNT=0, skipping worker node verification")
		}

		Eventually(func(g Gomega) {
			nodes, err := utils.GetReadyWorkerNodes(ctx, mgmtClient)
			g.Expect(err).NotTo(HaveOccurred())
			GinkgoWriter.Printf("Worker nodes: %d/%d Ready\n", len(nodes), cfg.WorkerCount)
			g.Expect(len(nodes)).To(BeNumerically(">=", cfg.WorkerCount),
				"expected at least %d ready worker nodes, got %d", cfg.WorkerCount, len(nodes))
		}).WithTimeout(30 * time.Minute).WithPolling(30 * time.Second).Should(Succeed())
	})

	It("should have all DPU nodes Ready in hosted cluster", func() {
		if cfg.WorkerCount == 0 {
			Skip("WORKER_COUNT=0, skipping DPU node verification")
		}

		Eventually(func(g Gomega) {
			nodes, err := utils.GetReadyWorkerNodes(ctx, hostedClient)
			g.Expect(err).NotTo(HaveOccurred())
			GinkgoWriter.Printf("DPU nodes: %d/%d Ready\n", len(nodes), cfg.WorkerCount)
			g.Expect(len(nodes)).To(BeNumerically(">=", cfg.WorkerCount),
				"expected at least %d ready DPU nodes, got %d", cfg.WorkerCount, len(nodes))
		}).WithTimeout(30 * time.Minute).WithPolling(30 * time.Second).Should(Succeed())
	})

	It("should have DPUDeployment in Ready state", func() {
		dpuDeployment := &unstructured.Unstructured{}
		dpuDeployment.SetGroupVersionKind(schema.GroupVersionKind{
			Group:   "svc.dpu.nvidia.com",
			Version: "v1alpha1",
			Kind:    "DPUDeployment",
		})

		key := client.ObjectKey{Namespace: cfg.DPFNamespace, Name: "dpudeployment"}

		Eventually(func(g Gomega) {
			err := mgmtClient.Get(ctx, key, dpuDeployment)
			g.Expect(err).NotTo(HaveOccurred(), "failed to get DPUDeployment")

			conditions, found, err := unstructured.NestedSlice(dpuDeployment.Object, "status", "conditions")
			g.Expect(err).NotTo(HaveOccurred())
			g.Expect(found).To(BeTrue(), "DPUDeployment has no status.conditions")

			readyFound := false
			for _, c := range conditions {
				cond, ok := c.(map[string]interface{})
				if !ok {
					continue
				}
				condType, _, _ := unstructured.NestedString(cond, "type")
				condStatus, _, _ := unstructured.NestedString(cond, "status")
				if condType == "Ready" {
					readyFound = true
					GinkgoWriter.Printf("DPUDeployment Ready=%s\n", condStatus)
					g.Expect(condStatus).To(Equal(string(metav1.ConditionTrue)),
						"DPUDeployment condition Ready is not True")
				}
			}
			g.Expect(readyFound).To(BeTrue(), "DPUDeployment has no Ready condition")
		}).WithTimeout(30 * time.Minute).WithPolling(30 * time.Second).Should(Succeed())
	})
})
