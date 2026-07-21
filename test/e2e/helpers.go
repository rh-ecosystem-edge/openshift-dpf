package e2e

import (
	"context"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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
