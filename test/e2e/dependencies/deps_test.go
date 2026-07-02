// Package dependencies tests DPUDeployment service dependency ordering.
// Section 12 of the DPF QA Test Plan.
// ALL tests in this section are explicitly DROPPED for GA (Low priority).
package dependencies_test

import (
	. "github.com/onsi/ginkgo/v2"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-DEP-001..006 — Dropped for GA (Low priority, explicitly excluded).
var _ = Describe("TC-DEP-001..006", Label(labels.Domain.DPUDeployment), func() {
	It("TC-DEP-001..006 are dropped for GA — Low priority", func() {
		Skip("TC-DEP-001..006: explicitly dropped for GA (Low priority)")
	})
})
