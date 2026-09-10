package e2e

import (
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestOVNKPodReadinessProblems(t *testing.T) {
	newHealthyPod := func() *corev1.Pod {
		return &corev1.Pod{
			Status: corev1.PodStatus{
				Phase: corev1.PodRunning,
				Conditions: []corev1.PodCondition{{
					Type:   corev1.PodReady,
					Status: corev1.ConditionTrue,
				}},
				ContainerStatuses: []corev1.ContainerStatus{{
					Name:  "ovnkube-node",
					Ready: true,
				}},
			},
		}
	}

	tests := []struct {
		name        string
		mutate      func(*corev1.Pod)
		wantProblem string
	}{
		{name: "fully ready"},
		{
			name: "pending",
			mutate: func(pod *corev1.Pod) {
				pod.Status.Phase = corev1.PodPending
			},
			wantProblem: "phase=Pending",
		},
		{
			name: "pod not ready",
			mutate: func(pod *corev1.Pod) {
				pod.Status.Conditions[0].Status = corev1.ConditionFalse
			},
			wantProblem: "Ready=False",
		},
		{
			name: "container not ready",
			mutate: func(pod *corev1.Pod) {
				pod.Status.ContainerStatuses[0].Ready = false
				pod.Status.ContainerStatuses[0].RestartCount = 4
			},
			wantProblem: "container=ovnkube-node ready=false restarts=4",
		},
		{
			name: "terminating",
			mutate: func(pod *corev1.Pod) {
				now := metav1.NewTime(time.Now())
				pod.DeletionTimestamp = &now
			},
			wantProblem: "terminating",
		},
		{
			name: "missing container status",
			mutate: func(pod *corev1.Pod) {
				pod.Status.ContainerStatuses = nil
			},
			wantProblem: "no container statuses",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pod := newHealthyPod()
			if tt.mutate != nil {
				tt.mutate(pod)
			}

			problems := ovnKPodReadinessProblems(pod)
			if tt.wantProblem == "" {
				if len(problems) != 0 {
					t.Fatalf("healthy pod reported problems: %v", problems)
				}
				return
			}
			if !strings.Contains(strings.Join(problems, ", "), tt.wantProblem) {
				t.Fatalf("problems %v do not contain %q", problems, tt.wantProblem)
			}
		})
	}
}
