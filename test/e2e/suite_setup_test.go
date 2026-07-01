package e2e_test

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
)

var cfg *config.E2EConfig

var _ = SynchronizedBeforeSuite(
	// Runs once on node 1 (serial)
	func(ctx context.Context) []byte {
		cfg = config.Load(configPath)
		err := framework.InitClients(
			cfg.MgmtKubeconfig,
			cfg.HostedClusterNamespace,
			cfg.HostedClusterName,
		)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "initialise Kubernetes clients")
		return nil
	},
	// Runs on all parallel nodes
	func(ctx context.Context, _ []byte) {
		cfg = config.Get()
	},
)

var _ = SynchronizedAfterSuite(
	func() {},
	func() {},
)
