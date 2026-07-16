package framework

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	// DPUEnabledLabel is the NFD label that marks a node as DPU-capable.
	DPUEnabledLabel = "feature.node.kubernetes.io/dpu-enabled"

	// WorkerDPURole is the node-role label applied to DPU-enabled worker nodes.
	WorkerDPURole = "node-role.kubernetes.io/worker-dpu"
)

// ListDPUWorkerNodes returns all management-cluster nodes that host DPUs.
func ListDPUWorkerNodes(ctx context.Context, c client.Client) ([]corev1.Node, error) {
	nodeList := &corev1.NodeList{}
	if err := c.List(ctx, nodeList, client.MatchingLabels{DPUEnabledLabel: ""}); err != nil {
		return nil, fmt.Errorf("list DPU worker nodes: %w", err)
	}
	return nodeList.Items, nil
}

// ListWorkerNodes returns all non-control-plane nodes in the cluster.
func ListWorkerNodes(ctx context.Context, c client.Client) ([]corev1.Node, error) {
	nodeList := &corev1.NodeList{}
	if err := c.List(ctx, nodeList); err != nil {
		return nil, fmt.Errorf("list nodes: %w", err)
	}
	var workers []corev1.Node
	for _, n := range nodeList.Items {
		if _, isMaster := n.Labels["node-role.kubernetes.io/master"]; !isMaster {
			if _, isCP := n.Labels["node-role.kubernetes.io/control-plane"]; !isCP {
				workers = append(workers, n)
			}
		}
	}
	return workers, nil
}

// NodeIsReady returns true if the node has NodeReady=True condition.
func NodeIsReady(n corev1.Node) bool {
	for _, c := range n.Status.Conditions {
		if c.Type == corev1.NodeReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

// NodeHasTaint checks whether a node carries a specific taint.
func NodeHasTaint(n corev1.Node, key, effect string) bool {
	for _, t := range n.Spec.Taints {
		if t.Key == key && string(t.Effect) == effect {
			return true
		}
	}
	return false
}
