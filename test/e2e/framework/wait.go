package framework

import (
	"context"
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Timeout constants used across all test specs.
const (
	OperatorReadyTimeout     = 5 * time.Minute
	DPUNodeReadyTimeout      = 30 * time.Minute
	DPUDeploymentTimeout     = 75 * time.Minute
	CriticalServiceScanTimer = 12 * time.Minute
	RebootRecoveryTimeout    = 20 * time.Minute
	Iperf3TestTimeout        = 2 * time.Minute
	StabilityTestTimeout     = 10 * time.Hour

	// PollInterval is the default Gomega polling interval.
	PollInterval = 5 * time.Second
)

// statusConditioner is satisfied by any DPF CRD that exposes Status.Conditions.
type statusConditioner interface {
	client.Object
	GetConditions() []metav1.Condition
}

// EventuallyCheckReadyCondition polls until the named condition is True on obj.
// The ObservedGeneration guard prevents stale conditions from producing false positives.
func EventuallyCheckReadyCondition(ctx context.Context, c client.Client, obj statusConditioner, condType string, timeout time.Duration) {
	GinkgoHelper()
	key := client.ObjectKeyFromObject(obj)
	gomega.Eventually(func(g gomega.Gomega) {
		g.Expect(c.Get(ctx, key, obj)).To(gomega.Succeed())
		cond := meta.FindStatusCondition(obj.GetConditions(), condType)
		g.Expect(cond).NotTo(gomega.BeNil(), "condition %s not found on %s", condType, key)
		g.Expect(cond.ObservedGeneration).To(gomega.Equal(obj.GetGeneration()),
			"stale condition: observedGeneration %d != generation %d", cond.ObservedGeneration, obj.GetGeneration())
		g.Expect(cond.Status).To(gomega.Equal(metav1.ConditionTrue),
			"condition %s = %s: %s", condType, cond.Status, cond.Message)
	}).WithContext(ctx).WithTimeout(timeout).WithPolling(PollInterval).Should(gomega.Succeed())
}

// EventuallyCheckConditionFalse polls until the named condition is False on obj.
func EventuallyCheckConditionFalse(ctx context.Context, c client.Client, obj statusConditioner, condType string, timeout time.Duration) {
	GinkgoHelper()
	key := client.ObjectKeyFromObject(obj)
	gomega.Eventually(func(g gomega.Gomega) {
		g.Expect(c.Get(ctx, key, obj)).To(gomega.Succeed())
		cond := meta.FindStatusCondition(obj.GetConditions(), condType)
		g.Expect(cond).NotTo(gomega.BeNil(), "condition %s not found on %s", condType, key)
		g.Expect(cond.Status).To(gomega.Equal(metav1.ConditionFalse),
			"condition %s = %s: %s", condType, cond.Status, cond.Message)
	}).WithContext(ctx).WithTimeout(timeout).WithPolling(PollInterval).Should(gomega.Succeed())
}

// ByTracker deduplicates Ginkgo By() calls within Eventually loops.
// Only logs when a key's message changes, avoiding CI log flooding.
type ByTracker struct {
	last map[string]string
}

// NewByTracker creates an initialised ByTracker.
func NewByTracker() *ByTracker {
	return &ByTracker{last: map[string]string{}}
}

// By emits a GinkgoWriter log only when the message for key has changed.
func (t *ByTracker) By(key, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	if t.last[key] != msg {
		GinkgoWriter.Println(msg)
		t.last[key] = msg
	}
}
