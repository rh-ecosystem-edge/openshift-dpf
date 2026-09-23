package e2e

import (
	"context"
	"fmt"
	"strings"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
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

type PodInfo struct {
	Name      string
	Namespace string
	NodeName  string
	IP        string
}

func discoverHBNPods(ctx context.Context, c client.Client, restCfg *rest.Config, cs *kubernetes.Clientset, namespace string, dpuWorkerNodes []corev1.Node) ([]PodInfo, error) {
	pods, err := utils.GetRunningPods(ctx, c, namespace, nil)
	if err != nil {
		return nil, fmt.Errorf("listing pods in %s: %w", namespace, err)
	}

	var hbnPods []PodInfo
	for _, worker := range dpuWorkerNodes {
		var hbnPod *corev1.Pod
		for i := range pods {
			if pods[i].Spec.NodeName == worker.Name && strings.Contains(pods[i].Name, "-hbn-") {
				hbnPod = &pods[i]
				break
			}
		}
		if hbnPod == nil {
			return nil, fmt.Errorf("no doca-hbn pod found on DPU worker node %s", worker.Name)
		}

		ip, err := utils.GetPodIPFromInterface(ctx, restCfg, cs, namespace, hbnPod.Name, "doca-hbn", "pf2dpu2_if")
		if err != nil {
			return nil, fmt.Errorf("getting HBN pod IP on node %s: %w", worker.Name, err)
		}

		hbnPods = append(hbnPods, PodInfo{
			Name:      hbnPod.Name,
			Namespace: namespace,
			NodeName:  worker.Name,
			IP:        ip,
		})
	}
	return hbnPods, nil
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
