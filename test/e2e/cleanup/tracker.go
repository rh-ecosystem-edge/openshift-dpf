// Package cleanup provides a three-tier lifecycle tracker for e2e test resources.
// Three-tier lifecycle manager with DPF-OCP label prefix.
package cleanup

import (
	"context"
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/ginkgo/v2/types"
	"github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	// GlobalLabel is applied to every resource created by the e2e suite.
	GlobalLabel = "dpf-ocp-e2e-cleanup"

	// ScopeLabelPrefix is the per-spec scope label prefix.
	ScopeLabelPrefix = "dpf-ocp-e2e-scope."
)

// ResourceGroup identifies a Kubernetes API resource to clean up.
type ResourceGroup struct {
	GVR       schema.GroupVersionResource
	Namespace string // empty = cluster-scoped
}

// Tracker manages cleanup of resources across three lifecycles:
//  1. Per-spec (cleaned by AfterEach)
//  2. Per-suite (cleaned by AfterSuite)
//  3. On-failure (skip cleanup to preserve evidence)
type Tracker struct {
	c           client.Client
	skipOnFail  bool
	namedFilter string // if non-empty, only clean scopes matching this name
	scopes      []scope
}

type scope struct {
	name      string
	resources []ResourceGroup
}

// New creates a Tracker.
// skipCleanupOnFailure=true preserves all test resources when any spec fails.
func New(c client.Client, skipCleanupOnFailure bool, namedFilter string) *Tracker {
	return &Tracker{
		c:           c,
		skipOnFail:  skipCleanupOnFailure,
		namedFilter: namedFilter,
	}
}

// RegisterScope registers a named cleanup scope with the resource types it owns.
func (t *Tracker) RegisterScope(name string, resources ...ResourceGroup) {
	t.scopes = append(t.scopes, scope{name: name, resources: resources})
}

// HandleScopeLifecycle should be called from AfterEach with the current SpecReport.
// It cleans up per-spec resources unless a skip condition is met:
//  1. Master skip flag (skipOnFail=true and any spec failed)
//  2. This spec was skipped
//  3. The spec failed and skipOnFail=true
//  4. The namedFilter is non-empty and doesn't match this spec
func (t *Tracker) HandleScopeLifecycle(ctx context.Context, report SpecReport) {
	GinkgoHelper()

	if t.skipOnFail && report.Failed() {
		By("cleanup: skipping resource cleanup — spec failed and SkipOnFailure=true")
		return
	}
	if report.State == types.SpecStateSkipped {
		return
	}
	if t.namedFilter != "" && report.LeafNodeText != t.namedFilter {
		return
	}
	t.cleanAll(ctx)
}

// CleanAll deletes all resources in all registered scopes. Called by AfterSuite.
func (t *Tracker) CleanAll(ctx context.Context) {
	GinkgoHelper()
	t.cleanAll(ctx)
}

func (t *Tracker) cleanAll(ctx context.Context) {
	GinkgoHelper()
	for _, s := range t.scopes {
		for _, rg := range s.resources {
			t.deleteLabeled(ctx, rg, map[string]string{GlobalLabel: "true"})
		}
	}
}

// deleteLabeled deletes all resources of rg that carry the given labels.
func (t *Tracker) deleteLabeled(ctx context.Context, rg ResourceGroup, labels map[string]string) {
	GinkgoHelper()

	list := &metav1.PartialObjectMetadataList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   rg.GVR.Group,
		Version: rg.GVR.Version,
		Kind:    rg.GVR.Resource, // controller-runtime accepts plural kind for list
	})
	opts := []client.ListOption{client.MatchingLabels(labels)}
	if rg.Namespace != "" {
		opts = append(opts, client.InNamespace(rg.Namespace))
	}
	if err := t.c.List(ctx, list, opts...); err != nil {
		fmt.Fprintf(GinkgoWriter, "cleanup: list %s: %v\n", rg.GVR, err)
		return
	}
	for i := range list.Items {
		obj := &list.Items[i]
		if err := t.c.Delete(ctx, obj); client.IgnoreNotFound(err) != nil {
			fmt.Fprintf(GinkgoWriter, "cleanup: delete %s %s/%s: %v\n",
				rg.GVR, obj.Namespace, obj.Name, err)
		}
	}
	gomega.Expect(true).To(gomega.BeTrue()) // keep Gomega happy in GinkgoHelper context
}
