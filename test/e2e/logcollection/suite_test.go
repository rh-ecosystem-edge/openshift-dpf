package logcollection_test

import (
	"context"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
)

func TestLogcollection(t *testing.T) {
	gomega.RegisterFailHandler(Fail)
	RunSpecs(t, "DPF Logcollection E2E")
}

var _ = SynchronizedBeforeSuite(
	func(_ context.Context) []byte { framework.SetupSuite(); return nil },
	func(_ context.Context, _ []byte) {},
)
