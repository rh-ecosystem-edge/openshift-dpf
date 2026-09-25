package e2e

import (
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"

	"github.com/openshift-dpf/test/manifests"
	"github.com/openshift-dpf/test/utils"
)

// verifyMixedWorkerEastWestConnectivity applies dedicated DPU-worker and regular-worker workloads,
// waits for a running pod on each worker type, verifies bidirectional east-west ping connectivity
// across the node boundary, then cleans up both workloads. Reusable by any mixed-worker test case.
func verifyMixedWorkerEastWestConnectivity() {
	By("Applying DPU-worker workload manifests (sriov-test-worker)")
	Expect(utils.ApplyManifests(ctx, mgmtClient, manifests.WorkloadManifestBytes())).To(Succeed())

	By("Applying regular-worker workload manifests (connectivity-test-regular-worker)")
	Expect(utils.ApplyManifests(ctx, mgmtClient, manifests.RegularWorkerWorkloadManifestBytes())).To(Succeed())

	DeferCleanup(func() {
		var cleanupErrs []error
		By("Removing DPU-worker workload manifests")
		if err := utils.DeleteManifests(ctx, mgmtClient, manifests.WorkloadManifestBytes()); err != nil {
			cleanupErrs = append(cleanupErrs, fmt.Errorf("DPU-worker workload cleanup: %w", err))
		}
		By("Removing regular-worker workload manifests")
		if err := utils.DeleteManifests(ctx, mgmtClient, manifests.RegularWorkerWorkloadManifestBytes()); err != nil {
			cleanupErrs = append(cleanupErrs, fmt.Errorf("regular-worker workload cleanup: %w", err))
		}
		Expect(cleanupErrs).To(BeEmpty(), "workload cleanup failures will affect subsequent tests")
	})

	By("Waiting for at least one connectivity-test-regular-worker pod to be Running")
	var regularPod corev1.Pod
	Eventually(func(g Gomega) {
		pods, err := utils.GetRunningPods(ctx, mgmtClient, cfg.WorkloadNamespace,
			map[string]string{"app": "connectivity-test-regular-worker"})
		g.Expect(err).NotTo(HaveOccurred())
		g.Expect(pods).NotTo(BeEmpty(), "no Running connectivity-test-regular-worker pods found")
		regularPod = pods[0]
	}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())
	GinkgoWriter.Printf("Regular-worker pod: %s on node %s (IP: %s)\n",
		regularPod.Name, regularPod.Spec.NodeName, regularPod.Status.PodIP)

	By("Waiting for at least one sriov-test-worker pod to be Running on a DPU worker")
	var dpuWorkerPod corev1.Pod
	Eventually(func(g Gomega) {
		pods, err := utils.GetRunningPods(ctx, mgmtClient, cfg.WorkloadNamespace,
			map[string]string{"app": "sriov-test-worker"})
		g.Expect(err).NotTo(HaveOccurred())
		g.Expect(pods).NotTo(BeEmpty(), "no Running sriov-test-worker pods found")
		dpuWorkerPod = pods[0]
	}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

	dpuHostWorkerNames := make(map[string]struct{}, len(dpuHostWorkers))
	for _, n := range dpuHostWorkers {
		dpuHostWorkerNames[n.Name] = struct{}{}
	}
	Expect(dpuHostWorkerNames).To(HaveKey(dpuWorkerPod.Spec.NodeName),
		"sriov-test-worker pod %s scheduled on node %s which is not a DPU-enabled worker; "+
			"the DPU workload must run on DPU nodes to correctly test the mixed-worker connectivity path",
		dpuWorkerPod.Name, dpuWorkerPod.Spec.NodeName)
	GinkgoWriter.Printf("DPU-worker pod: %s on node %s (IP: %s)\n",
		dpuWorkerPod.Name, dpuWorkerPod.Spec.NodeName, dpuWorkerPod.Status.PodIP)

	By(fmt.Sprintf("East-west ping: regular-worker pod %s → DPU-worker pod %s (%s)",
		regularPod.Name, dpuWorkerPod.Name, dpuWorkerPod.Status.PodIP))
	Expect(utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
		cfg.WorkloadNamespace, regularPod.Name, "netshoot",
		dpuWorkerPod.Status.PodIP, cfg.PingCount, 0)).To(Succeed())

	By(fmt.Sprintf("East-west ping: DPU-worker pod %s → regular-worker pod %s (%s)",
		dpuWorkerPod.Name, regularPod.Name, regularPod.Status.PodIP))
	Expect(utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
		cfg.WorkloadNamespace, dpuWorkerPod.Name, "nginx",
		regularPod.Status.PodIP, cfg.PingCount, 0)).To(Succeed())

	GinkgoWriter.Printf("East-west connectivity verified: %s (%s) ↔ %s (%s)\n",
		regularPod.Spec.NodeName, regularPod.Status.PodIP,
		dpuWorkerPod.Spec.NodeName, dpuWorkerPod.Status.PodIP)
}
