package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	nvipamv1 "github.com/nvidia/doca-platform/third_party/api/nvipam/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

const (
	ovnNodeComponentLabel      = "app.kubernetes.io/component"
	ovnNodeComponentLabelValue = "ovnkube-node"
	hbnPodIPInterface          = "pf2dpu2_if"
)

// isReady reports whether the given conditions slice contains a Ready=True condition.
func isReady(conditions []metav1.Condition) bool {
	for _, c := range conditions {
		if c.Type == "Ready" && c.Status == metav1.ConditionTrue {
			return true
		}
	}
	return false
}

// listDPUServiceRevisions lists the DPUService revisions generated for a
// named service in a DPUDeployment.
func listDPUServiceRevisions(ctx context.Context, c client.Client, namespace, deploymentName, serviceName string) ([]dpuservicev1.DPUService, error) {
	serviceList := &dpuservicev1.DPUServiceList{}
	err := c.List(ctx, serviceList,
		client.InNamespace(namespace),
		client.MatchingLabels{
			dpuservicev1.ParentDPUDeploymentNameLabel:            namespace + "_" + deploymentName,
			dpuservicev1.ServiceReferenceInDPUDeploymentLabelKey: serviceName,
		})
	if err != nil {
		return nil, fmt.Errorf("listing DPUService revisions for %s: %w", serviceName, err)
	}
	return serviceList.Items, nil
}

// dpuServiceUIDs returns the UIDs of the supplied DPUService revisions.
func dpuServiceUIDs(services []dpuservicev1.DPUService) map[types.UID]bool {
	uids := make(map[types.UID]bool, len(services))
	for _, service := range services {
		uids[service.UID] = true
	}
	return uids
}

// podUIDsByNode groups pod UIDs by the node on which each pod is scheduled.
func podUIDsByNode(pods []corev1.Pod) map[string]map[types.UID]bool {
	uids := make(map[string]map[types.UID]bool)
	for _, pod := range pods {
		if _, ok := uids[pod.Spec.NodeName]; !ok {
			uids[pod.Spec.NodeName] = make(map[types.UID]bool)
		}
		uids[pod.Spec.NodeName][pod.UID] = true
	}
	return uids
}

// podUIDsAbsentFromBaseline returns current pod UIDs that were not present in the
// per-node baseline. The result can be passed to a replacement wait to track
// only pods that appeared during an update rollout.
func podUIDsAbsentFromBaseline(baseline, current map[string]map[types.UID]bool) map[string]map[types.UID]bool {
	added := make(map[string]map[types.UID]bool)
	for nodeName, currentUIDs := range current {
		for uid := range currentUIDs {
			if baseline[nodeName][uid] {
				continue
			}
			if added[nodeName] == nil {
				added[nodeName] = make(map[types.UID]bool)
			}
			added[nodeName][uid] = true
		}
	}
	return added
}

// podIsReady reports whether a pod is Running, not terminating, PodReady, and
// has no unready containers.
func podIsReady(pod *corev1.Pod) bool {
	if pod == nil || pod.DeletionTimestamp != nil || pod.Status.Phase != corev1.PodRunning {
		return false
	}

	readyCondition := false
	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
			readyCondition = true
			break
		}
	}
	if !readyCondition || len(pod.Status.ContainerStatuses) == 0 {
		return false
	}
	for _, status := range pod.Status.ContainerStatuses {
		if !status.Ready {
			return false
		}
	}
	return true
}

// PodInfo contains a pod's name, namespace, node, and IP.
type PodInfo struct {
	Name      string
	Namespace string
	NodeName  string
	IP        string
}

// HBNPodInfo adds HBN and DPU identity to the generic pod information.
type HBNPodInfo struct {
	PodInfo
	DPUNodeName string
	UID         types.UID
}

// discoverHBNPodsByDPUNode discovers running HBN pods and indexes them by the
// DPU node name associated with each hosted-cluster worker.
func discoverHBNPodsByDPUNode(ctx context.Context, c client.Client, restCfg *rest.Config, cs *kubernetes.Clientset, namespace string) (map[string]HBNPodInfo, error) {
	pods, err := utils.GetRunningPods(ctx, c, namespace, nil)
	if err != nil {
		return nil, fmt.Errorf("listing hosted DPU service pods in %s: %w", namespace, err)
	}

	hbnPods := make(map[string]HBNPodInfo)
	for i := range pods {
		hbnPod := &pods[i]
		if !strings.Contains(hbnPod.Name, "-hbn-") || hbnPod.DeletionTimestamp != nil {
			continue
		}

		node := &corev1.Node{}
		if err := c.Get(ctx, client.ObjectKey{Name: hbnPod.Spec.NodeName}, node); err != nil {
			return nil, fmt.Errorf("getting hosted node %s for HBN pod %s: %w",
				hbnPod.Spec.NodeName, hbnPod.Name, err)
		}
		dpuNodeName := node.Labels[provisioningv1.DPUNodeNameLabel]
		if dpuNodeName == "" {
			return nil, fmt.Errorf("hosted node %s has no %s label",
				hbnPod.Spec.NodeName, provisioningv1.DPUNodeNameLabel)
		}

		ip, err := utils.GetPodIPFromInterface(ctx, restCfg, cs, namespace, hbnPod.Name, "doca-hbn", hbnPodIPInterface)
		if err != nil {
			return nil, fmt.Errorf("getting %s IP from HBN pod %s: %w", hbnPodIPInterface, hbnPod.Name, err)
		}

		if _, exists := hbnPods[dpuNodeName]; exists {
			return nil, fmt.Errorf("multiple HBN pods found for DPU node %s", dpuNodeName)
		}

		hbnPods[dpuNodeName] = HBNPodInfo{
			PodInfo: PodInfo{
				Name:      hbnPod.Name,
				Namespace: namespace,
				NodeName:  hbnPod.Spec.NodeName,
				IP:        ip,
			},
			DPUNodeName: dpuNodeName,
			UID:         hbnPod.UID,
		}
	}
	return hbnPods, nil
}

// discoverHBNPods returns HBN pods in the same order as dpuWorkerNodes.
func discoverHBNPods(ctx context.Context, c client.Client, restCfg *rest.Config, cs *kubernetes.Clientset, namespace string, dpuWorkerNodes []corev1.Node) ([]PodInfo, error) {
	hbnPodsByDPUNode, err := discoverHBNPodsByDPUNode(ctx, c, restCfg, cs, namespace)
	if err != nil {
		return nil, err
	}

	hbnPodsByHostedNode := make(map[string]HBNPodInfo, len(hbnPodsByDPUNode))
	for _, hbnPod := range hbnPodsByDPUNode {
		hbnPodsByHostedNode[hbnPod.NodeName] = hbnPod
	}

	hbnPods := make([]PodInfo, 0, len(dpuWorkerNodes))
	for _, worker := range dpuWorkerNodes {
		hbnPod, exists := hbnPodsByHostedNode[worker.Name]
		if !exists {
			return nil, fmt.Errorf("no doca-hbn pod found on DPU worker node %s", worker.Name)
		}
		hbnPods = append(hbnPods, hbnPod.PodInfo)
	}
	return hbnPods, nil
}

func deletePodAndWait(ctx context.Context, c client.Client, namespace, podName string, podUID types.UID) {
	uid := podUID
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		Namespace: namespace,
		Name:      podName,
	}}
	err := c.Delete(ctx, pod, &client.DeleteOptions{
		Preconditions: &metav1.Preconditions{UID: &uid},
	})
	Expect(err == nil || apierrors.IsNotFound(err)).To(BeTrue(),
		"failed to delete pod %s: %v", podName, err)

	Eventually(func(g Gomega) {
		current := &corev1.Pod{}
		err := c.Get(ctx, client.ObjectKey{Namespace: namespace, Name: podName}, current)
		g.Expect(apierrors.IsNotFound(err)).To(BeTrue(), "pod %s must be deleted", podName)
	}).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())
}

func waitForHBNPodByDPUNode(ctx context.Context, c client.Client, restCfg *rest.Config, cs *kubernetes.Clientset,
	namespace, dpuNodeName string, previousPodUID types.UID, expectedIP string) HBNPodInfo {
	var currentPod HBNPodInfo
	By(fmt.Sprintf("Waiting for replacement HBN pod on DPU node %s to use IP %s", dpuNodeName, expectedIP))
	Eventually(func(g Gomega) {
		currentPods, err := discoverHBNPodsByDPUNode(ctx, c, restCfg, cs, namespace)
		g.Expect(err).NotTo(HaveOccurred())
		var exists bool
		currentPod, exists = currentPods[dpuNodeName]
		g.Expect(exists).To(BeTrue(), "HBN pod on DPU node %s must exist", dpuNodeName)
		g.Expect(currentPod.UID).NotTo(Equal(previousPodUID),
			"replacement HBN pod on DPU node %s must have a new UID", dpuNodeName)
		g.Expect(currentPod.IP).To(Equal(expectedIP),
			"HBN pod on DPU node %s must use the expected IP", dpuNodeName)
	}).WithTimeout(10 * time.Minute).WithPolling(15 * time.Second).Should(Succeed())
	return currentPod
}

func findReadyDPUWithHBNPod(ctx context.Context, c client.Client, namespace string,
	hbnPods map[string]HBNPodInfo) (provisioningv1.DPU, error) {
	dpuList := &provisioningv1.DPUList{}
	if err := c.List(ctx, dpuList, client.InNamespace(namespace)); err != nil {
		return provisioningv1.DPU{}, fmt.Errorf("listing DPUs in %s: %w", namespace, err)
	}

	for i := range dpuList.Items {
		dpu := &dpuList.Items[i]
		if dpu.Status.Phase != provisioningv1.DPUReady {
			continue
		}
		if _, ok := hbnPods[dpu.Spec.DPUNodeName]; ok {
			return *dpu.DeepCopy(), nil
		}
	}

	return provisioningv1.DPU{}, fmt.Errorf("no Ready DPU has a matching HBN pod")
}

func cidrPoolContainsIP(pool *nvipamv1.CIDRPool, ip string) bool {
	parsedIP := net.ParseIP(ip)
	if parsedIP == nil {
		return false
	}
	for _, allocation := range pool.Status.Allocations {
		_, network, err := net.ParseCIDR(allocation.Prefix)
		if err == nil && network.Contains(parsedIP) {
			return true
		}
	}
	return false
}

func cidrPoolAllocationForNode(pool *nvipamv1.CIDRPool, nodeName string) (nvipamv1.CIDRPoolAllocation, bool) {
	for _, allocation := range pool.Status.Allocations {
		if allocation.NodeName == nodeName {
			return allocation, true
		}
	}
	return nvipamv1.CIDRPoolAllocation{}, false
}

func cidrPoolAllocationPrefixes(pool *nvipamv1.CIDRPool) map[string]string {
	prefixes := make(map[string]string, len(pool.Status.Allocations))
	for _, allocation := range pool.Status.Allocations {
		prefixes[allocation.NodeName] = allocation.Prefix
	}
	return prefixes
}

type WorkloadPods struct {
	Master         corev1.Pod
	Workers        []corev1.Pod
	HostNetWorkers []corev1.Pod
}

func discoverWorkloadPods(ctx context.Context, c client.Client, namespace string, dpuHostNodes []corev1.Node) (*WorkloadPods, error) {
	masterPods, err := utils.GetRunningPods(ctx, c, namespace, map[string]string{"app": "sriov-test-master"})
	if err != nil {
		return nil, fmt.Errorf("listing master pods: %w", err)
	}
	if len(masterPods) == 0 {
		return nil, fmt.Errorf("no sriov-test-master pod found in namespace %s", namespace)
	}

	workerPods, err := utils.GetRunningPods(ctx, c, namespace, map[string]string{"app": "sriov-test-worker"})
	if err != nil {
		return nil, fmt.Errorf("listing worker pods: %w", err)
	}

	hostnetPods, err := utils.GetRunningPods(ctx, c, namespace, map[string]string{"app": "sriov-test-worker-hostnetwork"})
	if err != nil {
		return nil, fmt.Errorf("listing hostnetwork pods: %w", err)
	}

	result := &WorkloadPods{
		Master: masterPods[0],
	}

	for _, node := range dpuHostNodes {
		wp := utils.FindPodOnNode(workerPods, node.Name)
		if wp == nil {
			return nil, fmt.Errorf("no sriov-test-worker pod found on node %s", node.Name)
		}
		result.Workers = append(result.Workers, *wp)

		hp := utils.FindPodOnNode(hostnetPods, node.Name)
		if hp == nil {
			return nil, fmt.Errorf("no sriov-test-worker-hostnetwork pod found on node %s", node.Name)
		}
		result.HostNetWorkers = append(result.HostNetWorkers, *hp)
	}

	return result, nil
}

// findOVNNodePodOnNode returns a ready OVN node pod scheduled on nodeName.
func findOVNNodePodOnNode(nodeName string) (*corev1.Pod, error) {
	podList := &corev1.PodList{}
	if err := hostedClient.List(ctx, podList,
		client.InNamespace(cfg.DPFNamespace),
		client.MatchingLabels{ovnNodeComponentLabel: ovnNodeComponentLabelValue},
	); err != nil {
		return nil, fmt.Errorf("listing OVN node pods in %s: %w", cfg.DPFNamespace, err)
	}
	for i := range podList.Items {
		if podList.Items[i].Spec.NodeName == nodeName &&
			len(ovnKPodReadinessProblems(&podList.Items[i])) == 0 {
			return &podList.Items[i], nil
		}
	}
	return nil, nil
}

// getInterfaceMTU executes `ip -j link show dev <iface>` in a pod container and
// parses the reported MTU.
func getInterfaceMTU(ctx context.Context, restCfg *rest.Config, cs *kubernetes.Clientset, namespace, podName, containerName, iface string) (int, error) {
	result, err := utils.ExecInPod(ctx, restCfg, cs, namespace, podName, containerName, []string{
		"ip", "-j", "link", "show", "dev", iface,
	})
	if err != nil {
		return 0, fmt.Errorf("getting %s MTU on pod %s: %w", iface, podName, err)
	}

	var links []struct {
		IfName string `json:"ifname"`
		MTU    int    `json:"mtu"`
	}
	if err := json.Unmarshal([]byte(result.Stdout), &links); err != nil {
		return 0, fmt.Errorf("parsing interface JSON for %s on pod %s: %w", iface, podName, err)
	}
	for _, link := range links {
		if link.IfName != iface {
			continue
		}
		if link.MTU <= 0 {
			return 0, fmt.Errorf("interface %s on pod %s has invalid MTU %d", iface, podName, link.MTU)
		}
		return link.MTU, nil
	}
	return 0, fmt.Errorf("interface %s not found in ip output on pod %s: %s", iface, podName, result.Stdout)
}

// deleteDPUDeploymentAndWait deletes the configured DPUDeployment and waits
// for it to be fully removed.
func deleteDPUDeploymentAndWait() {
	dpuDeployment := &dpuservicev1.DPUDeployment{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: cfg.DPFNamespace,
			Name:      cfg.DPUDeploymentName,
		},
	}
	err := mgmtClient.Delete(ctx, dpuDeployment)
	Expect(client.IgnoreNotFound(err)).To(Succeed(), "failed to delete DPUDeployment")

	By("Waiting for DPUDeployment to be fully removed")
	Eventually(func(g Gomega) {
		err := mgmtClient.Get(ctx, client.ObjectKeyFromObject(dpuDeployment), dpuDeployment)
		g.Expect(apierrors.IsNotFound(err)).To(BeTrue(),
			"DPUDeployment should be fully deleted, got: %v", err)
	}).WithTimeout(10 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

	GinkgoWriter.Printf("DPUDeployment %s deleted successfully\n", cfg.DPUDeploymentName)
}

// recreateDPUDeploymentFromBackup creates a new DPUDeployment using the
// ObjectMeta and Spec captured from a previous deployment.
func recreateDPUDeploymentFromBackup(backup *dpuservicev1.DPUDeployment) {
	Expect(backup).NotTo(BeNil(), "DPUDeployment backup should have been captured")

	newDeployment := &dpuservicev1.DPUDeployment{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:   backup.Namespace,
			Name:        backup.Name,
			Labels:      backup.Labels,
			Annotations: backup.Annotations,
		},
		Spec: backup.Spec,
	}

	Expect(mgmtClient.Create(ctx, newDeployment)).To(Succeed(),
		"failed to recreate DPUDeployment")
	GinkgoWriter.Printf("DPUDeployment %s recreated\n", newDeployment.Name)
}

// restoreDPUDeploymentFromBackup deletes the current DPUDeployment and
// recreates the captured object. This must happen after restoring
// DPFOperatorConfig.spec.networking.controlPlaneMTU so the operator
// provisions bridges with the restored value.
func restoreDPUDeploymentFromBackup(backup *dpuservicev1.DPUDeployment) {
	if backup == nil {
		return
	}
	deleteDPUDeploymentAndWait()
	recreateDPUDeploymentFromBackup(backup)
}
