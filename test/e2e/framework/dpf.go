package framework

import (
	"context"
	"fmt"
	"time"

	dpfprovisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// WaitForAllDPUNodesReady polls until all DPUNodes in ns are Ready.
func WaitForAllDPUNodesReady(ctx context.Context, c client.Client, ns string, expectedCount int, timeout time.Duration) {
	GinkgoHelper()
	tracker := NewByTracker()
	gomega.Eventually(func(g gomega.Gomega) {
		list := &dpfprovisioningv1.DPUNodeList{}
		g.Expect(c.List(ctx, list, client.InNamespace(ns))).To(gomega.Succeed())
		g.Expect(list.Items).To(gomega.HaveLen(expectedCount),
			"expected %d DPUNodes, got %d", expectedCount, len(list.Items))
		ready := 0
		for _, dpu := range list.Items {
			cond := meta.FindStatusCondition(dpu.Status.Conditions, string(dpfprovisioningv1.DPUNodeConditionReady))
			if cond != nil && cond.Status == metav1.ConditionTrue {
				ready++
			}
		}
		tracker.By("dpus", "DPUNodes ready: %d/%d", ready, expectedCount)
		g.Expect(ready).To(gomega.Equal(expectedCount))
	}).WithContext(ctx).WithTimeout(timeout).WithPolling(PollInterval).Should(gomega.Succeed())
}

// WaitForDPUDeploymentReady polls until the DPUDeployment has Ready=True.
func WaitForDPUDeploymentReady(ctx context.Context, c client.Client, dd *dpfservicev1.DPUDeployment, timeout time.Duration) {
	GinkgoHelper()
	EventuallyCheckReadyCondition(ctx, c, dd, "Ready", timeout)
}

// DeleteAndWaitGone deletes obj and polls until it no longer exists.
func DeleteAndWaitGone(ctx context.Context, c client.Client, obj client.Object, timeout time.Duration) {
	GinkgoHelper()
	gomega.Expect(c.Delete(ctx, obj)).To(gomega.Or(gomega.Succeed(), gomega.MatchError(gomega.ContainSubstring("not found"))))
	key := client.ObjectKeyFromObject(obj)
	gomega.Eventually(func(g gomega.Gomega) {
		err := c.Get(ctx, key, obj)
		g.Expect(err).To(gomega.Satisfy(func(e error) bool {
			return client.IgnoreNotFound(e) == nil && e != nil
		}), "object %s still exists", key)
	}).WithContext(ctx).WithTimeout(timeout).WithPolling(PollInterval).Should(gomega.Succeed())
}

// ListDPUServicePods returns pods belonging to a named DPUService in the DPF namespace.
// Uses the standard DPF label `svc.dpu.nvidia.com/name=<name>`.
func ListDPUServicePods(ctx context.Context, c client.Client, dpfNS, serviceName string) (int, error) {
	podList, err := ListRunningPods(ctx, c, dpfNS, map[string]string{
		"svc.dpu.nvidia.com/name": serviceName,
	})
	if err != nil {
		return 0, fmt.Errorf("list pods for service %s: %w", serviceName, err)
	}
	return len(podList), nil
}
