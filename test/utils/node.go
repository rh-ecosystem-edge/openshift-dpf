package utils

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const DPUEnabledLabel = "feature.node.kubernetes.io/dpu-enabled"

func GetReadyNodes(ctx context.Context, c client.Client, matchLabels map[string]string) ([]corev1.Node, error) {
	nodeList := &corev1.NodeList{}
	opts := []client.ListOption{}
	if len(matchLabels) > 0 {
		opts = append(opts, client.MatchingLabels(matchLabels))
	}
	if err := c.List(ctx, nodeList, opts...); err != nil {
		return nil, fmt.Errorf("listing nodes: %w", err)
	}

	var ready []corev1.Node
	for _, node := range nodeList.Items {
		if isNodeReady(node) {
			ready = append(ready, node)
		}
	}
	return ready, nil
}

func GetReadyWorkerNodes(ctx context.Context, c client.Client) ([]corev1.Node, error) {
	nodeList := &corev1.NodeList{}
	if err := c.List(ctx, nodeList); err != nil {
		return nil, fmt.Errorf("listing nodes: %w", err)
	}

	var workers []corev1.Node
	for _, node := range nodeList.Items {
		if _, isCP := node.Labels["node-role.kubernetes.io/control-plane"]; isCP {
			continue
		}
		if _, isWorker := node.Labels["node-role.kubernetes.io/worker"]; !isWorker {
			continue
		}
		if isNodeReady(node) {
			workers = append(workers, node)
		}
	}
	return workers, nil
}

func GetDPUEnabledNodes(ctx context.Context, c client.Client) ([]corev1.Node, error) {
	return GetReadyNodes(ctx, c, map[string]string{DPUEnabledLabel: ""})
}

func isNodeReady(node corev1.Node) bool {
	for _, cond := range node.Status.Conditions {
		if cond.Type == corev1.NodeReady && cond.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func GetReadyNodeCount(ctx context.Context, c client.Client, matchLabels map[string]string) (int, error) {
	nodes, err := GetReadyNodes(ctx, c, matchLabels)
	if err != nil {
		return 0, fmt.Errorf("counting ready nodes: %w", err)
	}
	return len(nodes), nil
}
