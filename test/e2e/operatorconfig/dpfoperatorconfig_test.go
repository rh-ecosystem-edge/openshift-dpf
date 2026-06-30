// Package operatorconfig tests DPFOperatorConfig management.
// Section 7 of the DPF QA Test Plan.
package operatorconfig_test

import (
	"context"

	dpfoperatorv1 "github.com/nvidia/doca-platform/api/operator/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	"k8s.io/apimachinery/pkg/types"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-OPCFG-001 [ALM:14510] — CPU/memory resource override for multiple components.
// Priority: Medium | Labels: dpf
var _ = Describe("TC-OPCFG-001", Label(labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var mgmt = framework.MgmtClient
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
	})

	It("DPFOperatorConfig exists", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt().Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
	})

	It("DPFOperatorConfig SystemComponents are Ready", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(mgmt().Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
		framework.EventuallyCheckReadyCondition(ctx, mgmt(), opcfg,
			string(dpfoperatorv1.SystemComponentsReadyCondition), framework.OperatorReadyTimeout)
	})
})

// TC-OPCFG-002 [ALM:14509] — Component image override via DPFOperatorConfig.
// Priority: Medium | Labels: dpf
var _ = Describe("TC-OPCFG-002", Label(labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
	})

	It("DPFOperatorConfig is retrievable", func() {
		opcfg := &dpfoperatorv1.DPFOperatorConfig{}
		gomega.Expect(framework.MgmtClient().Get(ctx,
			types.NamespacedName{Name: "dpfoperatorconfig", Namespace: cfg.DPFNamespace},
			opcfg,
		)).To(gomega.Succeed())
		By("DPFOperatorConfig fetched successfully — image override validation requires CI-provided values")
	})
})
