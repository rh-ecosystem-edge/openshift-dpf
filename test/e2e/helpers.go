package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

const (
	ovnNodeComponentLabel      = "app.kubernetes.io/component"
	ovnNodeComponentLabelValue = "ovnkube-node"
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
