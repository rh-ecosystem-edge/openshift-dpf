package framework

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// CleanupLabel is the global label applied to every resource created by e2e tests.
// The cleanup tracker uses this to identify and delete test resources after each spec.
const CleanupLabel = "dpf-ocp-e2e-cleanup"

// CreateNamespace creates a test namespace with cleanup labels.
func CreateNamespace(ctx context.Context, c client.Client, name string) (*corev1.Namespace, error) {
	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
			Labels: map[string]string{
				CleanupLabel: "true",
			},
		},
	}
	if err := c.Create(ctx, ns); client.IgnoreAlreadyExists(err) != nil {
		return nil, fmt.Errorf("create namespace %s: %w", name, err)
	}
	return ns, nil
}

// DeleteNamespace deletes a namespace and waits for it to be gone.
func DeleteNamespace(ctx context.Context, c client.Client, name string) error {
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name}}
	if err := c.Delete(ctx, ns); client.IgnoreNotFound(err) != nil {
		return fmt.Errorf("delete namespace %s: %w", name, err)
	}
	return nil
}

// CreateTestPod creates a simple pod for connectivity testing.
// The pod runs a long-lived sleep so tests can exec into it.
func CreateTestPod(ctx context.Context, c client.Client, ns, name, nodeName string) (*corev1.Pod, error) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels: map[string]string{
				CleanupLabel: "true",
				"app":        name,
			},
		},
		Spec: corev1.PodSpec{
			NodeName:      nodeName,
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{
				{
					Name:    "test",
					Image:   "quay.io/openshift/origin-cli:4.20",
					Command: []string{"sleep", "3600"},
				},
			},
		},
	}
	if err := c.Create(ctx, pod); client.IgnoreAlreadyExists(err) != nil {
		return nil, fmt.Errorf("create pod %s/%s: %w", ns, name, err)
	}
	return pod, nil
}

// ListRunningPods returns pods in the given namespace that are in Running phase.
func ListRunningPods(ctx context.Context, c client.Client, ns string, labels map[string]string) ([]corev1.Pod, error) {
	podList := &corev1.PodList{}
	opts := []client.ListOption{client.InNamespace(ns)}
	if len(labels) > 0 {
		opts = append(opts, client.MatchingLabels(labels))
	}
	if err := c.List(ctx, podList, opts...); err != nil {
		return nil, fmt.Errorf("list pods in %s: %w", ns, err)
	}
	var running []corev1.Pod
	for _, p := range podList.Items {
		if p.Status.Phase == corev1.PodRunning {
			running = append(running, p)
		}
	}
	return running, nil
}
