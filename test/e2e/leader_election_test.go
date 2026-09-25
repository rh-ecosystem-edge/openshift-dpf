package e2e

import (
	"fmt"

	. "github.com/onsi/ginkgo/v2"

	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
)

// Leader election targets for controllers deployed by DPF on the management cluster.
// Only controllers running as HA Deployments (replicas >= 2) are tested.
var leaderElectionTargets = []dpfe2e.LeaderElectionTarget{
	{
		Component:      "provisioning-controller",
		DeploymentName: "dpf-provisioning-controller-manager",
		LeaseName:      "provisioning.dpu.nvidia.com",
	},
}

var _ = Describe("DPF Leader Election Failover", Label("upstream", "leader-election"), func() {
	for _, target := range leaderElectionTargets {
		target := target
		It(fmt.Sprintf("%s leader pod is deleted and lease hands over", target.Component), func() {
			dpfe2e.ValidateLeaderElectionFailover(ctx, mgmtClient, target)
		})
	}
})
