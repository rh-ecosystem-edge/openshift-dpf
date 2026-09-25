package e2e

import (
	"fmt"
	"strings"
	"time"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

const (
	ovnKubeNodeComponent = "ovnkube-node"
)

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
	waitForDPUDeploymentReady()
	readyDPUWorkers := waitForHostedDPUWorkersReady(expectedDPUs)
	waitForOVNKPodsReady(readyDPUWorkers)
	waitForClusterHealth()
}

// skipIfClusterNotReadyForDPUReprovisioning protects disruptive tests from
// changing an already-degraded cluster. It is intended to be called from the
// test container's BeforeAll, after that test's configuration-specific skip
// checks have run.
func skipIfClusterNotReadyForDPUReprovisioning() {
	if reason := dpuReprovisioningPreflightFailure(); reason != "" {
		Skip("Skipping DPU reprovisioning test: " + reason)
	}
}

// dpuReprovisioningPreflightFailure performs a fast, read-only precondition
// check. Unlike waitForClusterHealth, it does not wait for recovery. Its pod
// policy intentionally matches checkPodsHealthyOnNodes, so a failure cannot be
// incorrectly attributed to the reprovisioning operation.
func dpuReprovisioningPreflightFailure() string {
	expectedDPUs := len(dpuHostWorkers)
	if expectedDPUs == 0 {
		return "no DPU-enabled host worker nodes discovered"
	}

	if failure := dpuDeploymentReadinessFailure(); failure != "" {
		return failure
	}
	if failure := dpuResourcesReadinessFailure(expectedDPUs); failure != "" {
		return failure
	}

	// Keep the precondition aligned with the final cluster-health assertion.
	// This prevents a pre-existing Pending or CrashLooping pod from being
	// attributed to the reprovisioning operation.
	podFailures := InterceptGomegaFailures(func() {
		checkPodsHealthyOnNodes(mgmtClient, dpuHostWorkers)
	})
	if len(podFailures) > 0 {
		return fmt.Sprintf("DPU host pods are unhealthy before the test: %s",
			strings.Join(podFailures, "; "))
	}

	readyNodes, failure := readyHostedDPUWorkers(expectedDPUs)
	if failure != "" {
		return failure
	}
	dpuWorkers = readyNodes

	if failure := ovnKPodsReadinessFailure(readyNodes); failure != "" {
		return failure
	}

	for _, cluster := range []struct {
		name string
		c    client.Client
	}{
		{name: "management", c: mgmtClient},
		{name: "hosted", c: hostedClient},
	} {
		failures := InterceptGomegaFailures(func() {
			checkClusterOperatorsHealthy(cluster.c, cluster.name)
		})
		if len(failures) > 0 {
			return fmt.Sprintf("%s cluster operators are unhealthy: %s",
				cluster.name, strings.Join(failures, "; "))
		}
	}

	return ""
}

func dpuDeploymentReadinessFailure() string {
	dpuDeployment := &dpuservicev1.DPUDeployment{}
	if err := mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.DPFNamespace,
		Name:      cfg.DPUDeploymentName,
	}, dpuDeployment); err != nil {
		return fmt.Sprintf("failed to read DPUDeployment %s/%s: %v",
			cfg.DPFNamespace, cfg.DPUDeploymentName, err)
	}
	if !isReady(dpuDeployment.Status.Conditions) {
		return fmt.Sprintf("DPUDeployment %s is not Ready", cfg.DPUDeploymentName)
	}
	return ""
}

func dpuResourcesReadinessFailure(expectedDPUs int) string {
	dpuSetList := &provisioningv1.DPUSetList{}
	if err := mgmtClient.List(ctx, dpuSetList, client.InNamespace(cfg.DPFNamespace)); err != nil {
		return fmt.Sprintf("failed to list DPUSets in %s: %v", cfg.DPFNamespace, err)
	}
	dpuSets := dpuSetsOwnedByConfiguredDeployment(dpuSetList.Items)
	if len(dpuSets) == 0 {
		return fmt.Sprintf("no DPUSets owned by DPUDeployment %s found", cfg.DPUDeploymentName)
	}

	dpuList := &provisioningv1.DPUList{}
	if err := mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace)); err != nil {
		return fmt.Sprintf("failed to list DPUs in %s: %v", cfg.DPFNamespace, err)
	}
	managedDPUs := dpusOwnedByDPUSets(dpuList.Items, dpuSets)
	if len(managedDPUs) < expectedDPUs {
		return fmt.Sprintf("expected at least %d DPUs, found %d", expectedDPUs, len(managedDPUs))
	}

	var notReadyDPUs []string
	for _, dpu := range managedDPUs {
		if dpu.Status.Phase != provisioningv1.DPUReady {
			notReadyDPUs = append(notReadyDPUs,
				fmt.Sprintf("%s=%s", dpu.Name, dpu.Status.Phase))
		}
	}
	if len(notReadyDPUs) > 0 {
		return fmt.Sprintf("DPUs are not Ready: %s", strings.Join(notReadyDPUs, ", "))
	}
	return ""
}

func dpuSetsOwnedByConfiguredDeployment(dpuSets []provisioningv1.DPUSet) []provisioningv1.DPUSet {
	managed := make([]provisioningv1.DPUSet, 0, len(dpuSets))
	for _, dpuSet := range dpuSets {
		for _, owner := range dpuSet.OwnerReferences {
			if owner.APIVersion == dpuservicev1.GroupVersion.String() &&
				owner.Kind == dpuservicev1.DPUDeploymentKind &&
				owner.Name == cfg.DPUDeploymentName {
				managed = append(managed, dpuSet)
				break
			}
		}
	}
	return managed
}

func dpusOwnedByDPUSets(dpus []provisioningv1.DPU, dpuSets []provisioningv1.DPUSet) []provisioningv1.DPU {
	dpuSetUIDs := make(map[string]string, len(dpuSets))
	for _, dpuSet := range dpuSets {
		dpuSetUIDs[dpuSet.Name] = string(dpuSet.UID)
	}

	managed := make([]provisioningv1.DPU, 0, len(dpus))
	for _, dpu := range dpus {
		for _, owner := range dpu.OwnerReferences {
			if owner.APIVersion != provisioningv1.GroupVersion.String() ||
				owner.Kind != provisioningv1.DPUSetKind {
				continue
			}

			dpuSetUID, exists := dpuSetUIDs[owner.Name]
			if !exists || (dpuSetUID != "" && dpuSetUID != string(owner.UID)) {
				continue
			}
			managed = append(managed, dpu)
			break
		}
	}
	return managed
}

func readyHostedDPUWorkers(expectedNodes int) ([]corev1.Node, string) {
	readyNodes, err := utils.GetReadyWorkerNodes(ctx, hostedClient)
	if err != nil {
		return nil, fmt.Sprintf("failed to list Ready hosted worker nodes: %v", err)
	}
	dpuWorkers := filterDPUWorkersByDeployment(readyNodes,
		fmt.Sprintf("%s_%s", cfg.DPFNamespace, cfg.DPUDeploymentName))
	if len(dpuWorkers) < expectedNodes {
		return nil, fmt.Sprintf("expected at least %d Ready hosted DPU workers, found %d",
			expectedNodes, len(dpuWorkers))
	}
	return dpuWorkers, ""
}

func filterDPUWorkersByDeployment(nodes []corev1.Node, deploymentLabelValue string) []corev1.Node {
	dpuWorkers := make([]corev1.Node, 0, len(nodes))
	for _, node := range nodes {
		if node.Labels[dpuservicev1.ParentDPUDeploymentNameLabel] == deploymentLabelValue {
			dpuWorkers = append(dpuWorkers, node)
		}
	}
	return dpuWorkers
}

func ovnKPodsReadinessFailure(nodes []corev1.Node) string {
	podList := &corev1.PodList{}
	if err := hostedClient.List(ctx, podList,
		client.InNamespace(cfg.DPFNamespace),
		client.MatchingLabels{"app.kubernetes.io/component": ovnKubeNodeComponent},
	); err != nil {
		return fmt.Sprintf("failed to list OVN-K pods in %s: %v", cfg.DPFNamespace, err)
	}
	if failures := ovnKPodReadinessFailures(nodes, podList.Items); len(failures) > 0 {
		return strings.Join(failures, "; ")
	}
	return ""
}

func waitForDPUResourcesReady(expectedDPUs int) {
	By(fmt.Sprintf("Waiting for %d DPU resources to be Ready", expectedDPUs))
	Eventually(func() string {
		return dpuResourcesReadinessFailure(expectedDPUs)
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).
		WithPolling(30 * time.Second).Should(BeEmpty())
}

func waitForDPUDeploymentReady() {
	By(fmt.Sprintf("Waiting for DPUDeployment %s to be Ready", cfg.DPUDeploymentName))
	Eventually(func() string {
		return dpuDeploymentReadinessFailure()
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).
		WithPolling(30 * time.Second).Should(BeEmpty())
}

func waitForHostedDPUWorkersReady(expectedNodes int) []corev1.Node {
	By(fmt.Sprintf("Waiting for %d DPU worker nodes to be Ready in the hosted cluster", expectedNodes))
	var readyNodes []corev1.Node
	Eventually(func() string {
		nodes, failure := readyHostedDPUWorkers(expectedNodes)
		if failure == "" {
			readyNodes = nodes
		}
		return failure
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).
		WithPolling(30 * time.Second).Should(BeEmpty())

	// Refresh the suite-level view after reprovisioning so later tests do not
	// retain stale Node objects.
	dpuWorkers = readyNodes
	return readyNodes
}

func waitForOVNKPodsReady(nodes []corev1.Node) {
	By("Waiting for a fully Ready OVN-K pod on every hosted-cluster DPU worker")
	Eventually(func() string {
		return ovnKPodsReadinessFailure(nodes)
	}).WithTimeout(cfg.ClusterHealthTimeout).
		WithPolling(30 * time.Second).Should(BeEmpty())
}

func ovnKPodReadinessFailures(nodes []corev1.Node, pods []corev1.Pod) []string {
	var failures []string
	for _, node := range nodes {
		var healthyPods []string
		var podDiagnostics []string
		for i := range pods {
			pod := &pods[i]
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

		if len(healthyPods) == 0 {
			failures = append(failures,
				fmt.Sprintf("node %s has no fully Ready OVN-K pod; matching pods: %v",
					node.Name, podDiagnostics))
		}
	}
	return failures
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
