// Package nodeeffect covers NodeEffect tests.
// Section 9 of the DPF QA Test Plan.
// TC-NE-001 and TC-NE-002 are explicitly DROPPED for GA (Low priority).
package nodeeffect_test

import (
	. "github.com/onsi/ginkgo/v2"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-NE-001 [ALM:14439] — Dropped for GA (Low priority).
var _ = Describe("TC-NE-001", Label(labels.Domain.DPUDeployment), func() {
	It("TC-NE-001 is dropped for GA (Low priority)", func() {
		Skip("TC-NE-001: explicitly dropped for GA")
	})
})

// TC-NE-002 [ALM:14438] — Dropped for GA (Low priority).
var _ = Describe("TC-NE-002", Label(labels.Domain.DPUDeployment), func() {
	It("TC-NE-002 is dropped for GA (Low priority)", func() {
		Skip("TC-NE-002: explicitly dropped for GA")
	})
})
