package utils

import (
	"bytes"
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type ExecResult struct {
	Stdout string
	Stderr string
}

func ExecInPod(ctx context.Context, cfg *rest.Config, cs *kubernetes.Clientset, namespace, podName, containerName string, command []string) (*ExecResult, error) {
	req := cs.CoreV1().RESTClient().Post().
		Resource("pods").
		Namespace(namespace).
		Name(podName).
		SubResource("exec")

	req.VersionedParams(&corev1.PodExecOptions{
		Container: containerName,
		Command:   command,
		Stdout:    true,
		Stderr:    true,
	}, scheme.ParameterCodec)

	exec, err := remotecommand.NewSPDYExecutor(cfg, "POST", req.URL())
	if err != nil {
		return nil, fmt.Errorf("creating SPDY executor: %w", err)
	}

	var stdout, stderr bytes.Buffer
	if err := exec.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdout: &stdout,
		Stderr: &stderr,
	}); err != nil {
		return &ExecResult{Stdout: stdout.String(), Stderr: stderr.String()}, fmt.Errorf("exec in pod %s/%s: %w (stderr: %s)", namespace, podName, err, stderr.String())
	}

	return &ExecResult{Stdout: stdout.String(), Stderr: stderr.String()}, nil
}

func PingFromPod(ctx context.Context, cfg *rest.Config, cs *kubernetes.Clientset, namespace, podName, containerName, destIP string, count, mtu int) error {
	cmd := []string{"ping", "-c", strconv.Itoa(count)}
	if mtu > 0 {
		cmd = append(cmd, "-M", "do", "-s", strconv.Itoa(mtu))
	}
	cmd = append(cmd, destIP)

	result, err := ExecInPod(ctx, cfg, cs, namespace, podName, containerName, cmd)
	if err != nil {
		return fmt.Errorf("ping from %s to %s: %w", podName, destIP, err)
	}

	packetLoss, err := parsePacketLoss(result.Stdout)
	if err != nil {
		return fmt.Errorf("parsing ping output from %s: %w", podName, err)
	}

	if packetLoss > 0 {
		return fmt.Errorf("ping from %s to %s had %d%% packet loss", podName, destIP, packetLoss)
	}
	return nil
}

var packetLossRegex = regexp.MustCompile(`(\d+)% packet loss`)

func parsePacketLoss(output string) (int, error) {
	matches := packetLossRegex.FindStringSubmatch(output)
	if len(matches) < 2 {
		return -1, fmt.Errorf("could not parse packet loss from output: %s", output)
	}
	loss, err := strconv.Atoi(matches[1])
	if err != nil {
		return -1, fmt.Errorf("parsing packet loss value %q: %w", matches[1], err)
	}
	return loss, nil
}

func GetPodIPFromInterface(ctx context.Context, cfg *rest.Config, cs *kubernetes.Clientset, namespace, podName, containerName, ifaceName string) (string, error) {
	result, err := ExecInPod(ctx, cfg, cs, namespace, podName, containerName, []string{
		"ip", "a", "show", ifaceName,
	})
	if err != nil {
		return "", fmt.Errorf("getting IP from interface %s on pod %s: %w", ifaceName, podName, err)
	}

	for _, line := range strings.Split(result.Stdout, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "inet ") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				ip := strings.Split(fields[1], "/")[0]
				return ip, nil
			}
		}
	}
	return "", fmt.Errorf("no IPv4 address found on interface %s in pod %s", ifaceName, podName)
}

func GetRunningPods(ctx context.Context, c client.Client, namespace string, labelSelector map[string]string) ([]corev1.Pod, error) {
	podList := &corev1.PodList{}
	opts := []client.ListOption{client.InNamespace(namespace)}
	if len(labelSelector) > 0 {
		opts = append(opts, client.MatchingLabels(labelSelector))
	}
	if err := c.List(ctx, podList, opts...); err != nil {
		return nil, fmt.Errorf("listing pods in %s: %w", namespace, err)
	}

	var running []corev1.Pod
	for _, pod := range podList.Items {
		if pod.Status.Phase == corev1.PodRunning {
			running = append(running, pod)
		}
	}
	return running, nil
}

func FindPodOnNode(pods []corev1.Pod, nodeName string) *corev1.Pod {
	for i := range pods {
		if pods[i].Spec.NodeName == nodeName {
			return &pods[i]
		}
	}
	return nil
}
