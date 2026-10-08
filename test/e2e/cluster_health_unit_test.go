package e2e

import (
	"strings"
	"testing"
	"time"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestFilterDPUWorkersByDeployment(t *testing.T) {
	deploymentLabelValue := "dpf-operator-system_dpudeployment"
	nodes := []corev1.Node{
		{ObjectMeta: metav1.ObjectMeta{Name: "dpu-worker", Labels: map[string]string{
			dpuservicev1.ParentDPUDeploymentNameLabel: deploymentLabelValue,
		}}},
		{ObjectMeta: metav1.ObjectMeta{Name: "regular-worker"}},
		{ObjectMeta: metav1.ObjectMeta{Name: "other-dpu-worker", Labels: map[string]string{
			dpuservicev1.ParentDPUDeploymentNameLabel: "dpf-operator-system_other-deployment",
		}}},
	}

	got := filterDPUWorkersByDeployment(nodes, deploymentLabelValue)
	if len(got) != 1 || got[0].Name != "dpu-worker" {
		t.Fatalf("filterDPUWorkersByDeployment() = %v, want only dpu-worker", got)
	}
}

func TestDPUsOwnedByDPUSets(t *testing.T) {
	dpuSets := []provisioningv1.DPUSet{
		{ObjectMeta: metav1.ObjectMeta{Name: "managed", UID: "managed-uid"}},
	}
	owner := metav1.OwnerReference{
		APIVersion: provisioningv1.GroupVersion.String(),
		Kind:       provisioningv1.DPUSetKind,
		Name:       "managed",
		UID:        "managed-uid",
	}
	staleOwner := owner
	staleOwner.UID = "old-uid"

	dpus := []provisioningv1.DPU{
		{ObjectMeta: metav1.ObjectMeta{Name: "managed-dpu", OwnerReferences: []metav1.OwnerReference{owner}}},
		{ObjectMeta: metav1.ObjectMeta{Name: "stale-dpu", OwnerReferences: []metav1.OwnerReference{staleOwner}}},
		{ObjectMeta: metav1.ObjectMeta{Name: "unrelated-dpu", OwnerReferences: []metav1.OwnerReference{{
			APIVersion: provisioningv1.GroupVersion.String(),
			Kind:       provisioningv1.DPUSetKind,
			Name:       "other",
		}}}},
	}

	got := dpusOwnedByDPUSets(dpus, dpuSets)
	if len(got) != 1 || got[0].Name != "managed-dpu" {
		t.Fatalf("dpusOwnedByDPUSets() = %v, want only managed-dpu", got)
	}
}

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
