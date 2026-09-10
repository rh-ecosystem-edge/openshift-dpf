package e2e

import (
	"fmt"
	"strings"
	"time"

	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

const ovnKubeNodeComponent = "ovnkube-node"

var _ = Describe("Cluster Health Verification", Label("cluster-health"), func() {
	Describe("Cluster Operators", func() {
		It("all cluster operators are healthy on the management cluster", func() {
			checkClusterOperatorsHealthy(mgmtClient, "management")
		})

		It("all cluster operators are healthy on the hosted cluster", func() {
			checkClusterOperatorsHealthy(hostedClient, "hosted")
		})
	})

	Describe("DPU Worker Pods", func() {
		It("all pods on DPU worker nodes are Running and not CrashLooping", func() {
			Expect(dpuHostWorkers).NotTo(BeEmpty(), "no DPU-enabled host worker nodes discovered")
			checkPodsHealthyOnNodes(mgmtClient, dpuHostWorkers)
		})
	})
})

// waitForClusterHealth waits for the full cluster to be healthy after an
// operation. Operator health checks use the configured timeout to allow
// transient flapping to settle before asserting.
func waitForClusterHealth() {
	By("Waiting for management operators, hosted operators, and DPU-host pods to be healthy")
	Eventually(func() []string {
		return InterceptGomegaFailures(func() {
			checkClusterOperatorsHealthy(mgmtClient, "management")
			checkClusterOperatorsHealthy(hostedClient, "hosted")
			checkPodsHealthyOnNodes(mgmtClient, dpuHostWorkers)
		})
	}).WithTimeout(cfg.ClusterHealthTimeout).WithPolling(30 * time.Second).Should(BeEmpty())
}

// waitForClusterHealthAfterDPUReprovisioning is the recovery gate for tests
// that recreate or reprovision DPUs. Keeping the ordering here prevents new
// disruptive tests from checking cluster health before DPU networking has
// converged.
func waitForClusterHealthAfterDPUReprovisioning() {
	expectedDPUs := len(dpuHostWorkers)
	Expect(expectedDPUs).To(BeNumerically(">", 0),
		"no DPU-enabled host worker nodes discovered")

	waitForDPUResourcesReady(expectedDPUs)
	readyDPUWorkers := waitForHostedDPUWorkersReady(expectedDPUs)
	waitForOVNKPodsReady(readyDPUWorkers)
	waitForClusterHealth()
}

func waitForDPUResourcesReady(expectedDPUs int) {
	By(fmt.Sprintf("Waiting for %d DPU resources to be Ready", expectedDPUs))
	Eventually(func(g Gomega) {
		dpuList := &provisioningv1.DPUList{}
		g.Expect(mgmtClient.List(ctx, dpuList,
			client.InNamespace(cfg.DPFNamespace))).To(Succeed())

		readyCount := 0
		var notReady []string
		for _, dpu := range dpuList.Items {
			if dpu.Status.Phase == provisioningv1.DPUReady {
				readyCount++
				continue
			}
			notReady = append(notReady, fmt.Sprintf("%s=%s", dpu.Name, dpu.Status.Phase))
		}

		g.Expect(readyCount).To(BeNumerically(">=", expectedDPUs),
			"expected at least %d Ready DPUs, got %d; non-Ready DPUs: %v",
			expectedDPUs, readyCount, notReady)
		g.Expect(notReady).To(BeEmpty(),
			"all DPU resources must be Ready before checking OVN-K; non-Ready DPUs: %v",
			notReady)
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).
		WithPolling(30 * time.Second).Should(Succeed())
}

func waitForHostedDPUWorkersReady(expectedNodes int) []corev1.Node {
	By(fmt.Sprintf("Waiting for %d DPU worker nodes to be Ready in the hosted cluster", expectedNodes))
	var readyNodes []corev1.Node
	Eventually(func(g Gomega) {
		nodes, err := utils.GetReadyWorkerNodes(ctx, hostedClient)
		g.Expect(err).NotTo(HaveOccurred())
		g.Expect(len(nodes)).To(BeNumerically(">=", expectedNodes),
			"expected at least %d Ready DPU worker nodes, got %d",
			expectedNodes, len(nodes))
		readyNodes = nodes
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).
		WithPolling(30 * time.Second).Should(Succeed())

	// Refresh the suite-level view after reprovisioning so later tests do not
	// retain stale Node objects.
	dpuWorkers = readyNodes
	return readyNodes
}

func waitForOVNKPodsReady(nodes []corev1.Node) {
	By("Waiting for a fully Ready OVN-K pod on every hosted-cluster DPU worker")
	Eventually(func(g Gomega) {
		podList := &corev1.PodList{}
		g.Expect(hostedClient.List(ctx, podList,
			client.InNamespace(cfg.DPFNamespace),
			client.MatchingLabels{"app.kubernetes.io/component": ovnKubeNodeComponent},
		)).To(Succeed())

		for _, node := range nodes {
			var healthyPods []string
			var podDiagnostics []string
			for i := range podList.Items {
				pod := &podList.Items[i]
				if pod.Spec.NodeName != node.Name {
					continue
				}

				problems := ovnKPodReadinessProblems(pod)
				if len(problems) == 0 {
					healthyPods = append(healthyPods, pod.Name)
					continue
				}
				podDiagnostics = append(podDiagnostics,
					fmt.Sprintf("%s: %s", pod.Name, strings.Join(problems, ", ")))
			}

			g.Expect(healthyPods).NotTo(BeEmpty(),
				"node %s has no fully Ready OVN-K pod; matching pods: %v",
				node.Name, podDiagnostics)
		}
	}).WithTimeout(cfg.ClusterHealthTimeout).
		WithPolling(30 * time.Second).Should(Succeed())
}

// ovnKPodReadinessProblems returns an empty slice only when a pod is safe to
// treat as recovered. It is deliberately side-effect free so the readiness
// contract can be unit-tested without a cluster.
func ovnKPodReadinessProblems(pod *corev1.Pod) []string {
	var problems []string
	if pod.DeletionTimestamp != nil {
		problems = append(problems, "terminating")
	}
	if pod.Status.Phase != corev1.PodRunning {
		problems = append(problems, fmt.Sprintf("phase=%s", pod.Status.Phase))
	}

	podReady := false
	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
			podReady = true
			break
		}
	}
	if !podReady {
		problems = append(problems, "Ready=False")
	}

	if len(pod.Status.ContainerStatuses) == 0 {
		problems = append(problems, "no container statuses")
	}
	for _, status := range pod.Status.ContainerStatuses {
		if !status.Ready {
			problems = append(problems, fmt.Sprintf("container=%s ready=false restarts=%d",
				status.Name, status.RestartCount))
		}
	}
	return problems
}

// checkPodsHealthyOnNodes verifies that all pods on the given nodes are Running
// and not in CrashLoopBackOff. Completed (Succeeded) pods are ignored.
func checkPodsHealthyOnNodes(c client.Client, nodes []corev1.Node) {
	for _, node := range nodes {
		By(fmt.Sprintf("Checking pods on node %s", node.Name))

		podList := &corev1.PodList{}
		Expect(c.List(ctx, podList,
			client.MatchingFields{"spec.nodeName": node.Name},
		)).To(Succeed(), "failed to list pods on node %s", node.Name)

		var crashLooping []string
		var notRunning []string

		for _, pod := range podList.Items {
			if pod.Status.Phase == corev1.PodSucceeded {
				continue
			}

			if pod.Status.Phase != corev1.PodRunning {
				notRunning = append(notRunning, fmt.Sprintf("%s/%s (phase=%s)",
					pod.Namespace, pod.Name, pod.Status.Phase))
				continue
			}

			for _, cs := range pod.Status.ContainerStatuses {
				if cs.State.Waiting != nil && cs.State.Waiting.Reason == "CrashLoopBackOff" {
					crashLooping = append(crashLooping, fmt.Sprintf(
						"%s/%s container=%s restarts=%d",
						pod.Namespace, pod.Name, cs.Name, cs.RestartCount))
				}
			}
			for _, cs := range pod.Status.InitContainerStatuses {
				if cs.State.Waiting != nil && cs.State.Waiting.Reason == "CrashLoopBackOff" {
					crashLooping = append(crashLooping, fmt.Sprintf(
						"%s/%s init-container=%s restarts=%d",
						pod.Namespace, pod.Name, cs.Name, cs.RestartCount))
				}
			}
		}

		if len(notRunning) > 0 {
			GinkgoWriter.Printf("Non-running pods on node %s:\n", node.Name)
			for _, p := range notRunning {
				GinkgoWriter.Printf("  - %s\n", p)
			}
		}
		if len(crashLooping) > 0 {
			GinkgoWriter.Printf("CrashLooping pods on node %s:\n", node.Name)
			for _, p := range crashLooping {
				GinkgoWriter.Printf("  - %s\n", p)
			}
		}

		Expect(crashLooping).To(BeEmpty(),
			"found CrashLooping pods on node %s", node.Name)
		Expect(notRunning).To(BeEmpty(),
			"found non-running pods on node %s", node.Name)

		GinkgoWriter.Printf("Node %s: all %d pods healthy\n", node.Name, len(podList.Items))
	}
}
