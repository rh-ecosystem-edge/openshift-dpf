package e2e

import (
	"github.com/openshift-dpf/test/utils"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"testing"
)

func TestRecordTemporaryWorkerNodes(t *testing.T) {
	nodes := []corev1.Node{
		{ObjectMeta: metav1.ObjectMeta{Name: "temporary-1"}},
		{ObjectMeta: metav1.ObjectMeta{Name: "unrelated-new-worker"}},
		{ObjectMeta: metav1.ObjectMeta{Name: "temporary-11"}},
	}
	got := make(map[string]struct{})
	recordTemporaryWorkerNodes(nodes, "temporary-", got)
	if len(got) != 1 {
		t.Fatalf("tracking unrelated workers: %v", got)
	}
	if _, ok := got["temporary-1"]; !ok {
		t.Fatal("temporary worker was not tracked before Ready")
	}
	nodes[0].Labels = map[string]string{utils.DPUEnabledLabel: ""}
	got = make(map[string]struct{})
	recordTemporaryWorkerNodes(nodes, "temporary-", got)
	if len(got) != 0 {
		t.Fatalf("must not delete DPU worker: %v", got)
	}
}
