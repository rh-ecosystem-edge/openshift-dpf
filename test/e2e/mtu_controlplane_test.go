package e2e

import (
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	operatorv1 "github.com/nvidia/doca-platform/api/operator/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/manifests"
	"github.com/openshift-dpf/test/utils"
)

// controlPlaneMTU governs the out-of-band "management network" only: the
// host-side OOB bridge (br-ex) on the DPU-enabled host worker node
// (management cluster side) and its counterpart br-comm-ch bridge on the DPU
// node (hosted cluster side). It does NOT affect the high-speed OVN-Kubernetes data path
// (e.g. a workload pod's primary eth0 interface) -- that tracks
// highSpeedMTU instead, which this test leaves untouched.
const (
	ovnNodeContainerName  = "doca-ovnkube-controller"
	dpuOOBBridgeName      = "br-comm-ch"
	hostOOBBridgeName     = "br-ex"
	workloadContainerName = "nginx"

	// defaultControlPlaneMTU mirrors the CRD's +kubebuilder:default for
	// Networking.ControlPlaneMTU, used when the field is unset.
	defaultControlPlaneMTU = 1500
)

// TC-MTU-003: Change ControlplaneMTU Before DPUDeployment
//
// Deletes the existing DPUDeployment to reach a "no DPUDeployment" initial
// state, changes DPFOperatorConfig.spec.networking.controlPlaneMTU to a
// different value, recreates the DPUDeployment so the new MTU takes effect
// on provisioning, and verifies the new MTU propagated to the out-of-band
// management network: the host-side OOB bridge on the DPU host worker node
// (management cluster) and the br-comm-ch bridge on the DPU node (hosted
// cluster). The original controlPlaneMTU and DPUDeployment are restored at
// the end.
var _ = Describe("TC-MTU-003: Change ControlplaneMTU Before DPUDeployment", Label("mtu", "mtu-controlplane"), Ordered, func() {
	var (
		dpuDeploymentBackup           *dpuservicev1.DPUDeployment
		originalMTU                   int
		originalNetworkingWasNil      bool
		originalControlPlaneMTUWasNil bool
		newMTU                        int
		workloadPods                  *WorkloadPods
	)

	BeforeAll(func() {
		skipIfClusterNotReadyForDPUReprovisioning()
		dpuDeploymentBackup = getDPUDeployment().DeepCopy()
	})

	// Safety net: if a later spec fails, all following specs in this Ordered
	// container are skipped. AfterAll still runs and restores both the config
	// and the DPUDeployment for tests sharing the cluster.
	AfterAll(func() {
		if originalMTU == 0 {
			return
		}

		By("AfterAll: restoring the original controlPlaneMTU state")
		configRestoreErr := restoreControlPlaneMTU(
			originalMTU,
			originalNetworkingWasNil,
			originalControlPlaneMTUWasNil,
		)
		if configRestoreErr != nil {
			GinkgoWriter.Printf("AfterAll: failed to restore controlPlaneMTU: %v\n", configRestoreErr)
		}

		// The operator reads controlPlaneMTU while reconciling the
		// DPUDeployment. Recreate it after restoring the config so the
		// original MTU is propagated to the bridges as well.
		restoreDPUDeploymentFromBackup(dpuDeploymentBackup)
		if configRestoreErr == nil {
			By("AfterAll: waiting for cluster health after restoring the DPUDeployment")
			waitForClusterHealthAfterDPUReprovisioning()
		}

		Expect(configRestoreErr).NotTo(HaveOccurred(), "AfterAll: restoring controlPlaneMTU")
	})

	// ── Pre-conditions ──────────────────────────────────────────────────────

	It("pre-condition: should read current controlPlaneMTU and compute a different value", func() {
		var err error
		originalMTU, originalNetworkingWasNil, originalControlPlaneMTUWasNil, err = getControlPlaneMTU()
		Expect(err).NotTo(HaveOccurred())
		Expect(originalMTU).To(BeNumerically(">", 0))

		newMTU = toggleMTU(originalMTU)
		Expect(newMTU).NotTo(Equal(originalMTU))
		GinkgoWriter.Printf("controlPlaneMTU: %d -> %d\n", originalMTU, newMTU)
	})

	// ── Step 1: reach "no DPUDeployment" initial state ──────────────────────

	It("should delete the DPUDeployment", func() {
		deleteDPUDeploymentAndWait()
	})

	// ── Step 1: change controlPlaneMTU before DPUDeployment exists ─────────

	It("should change controlPlaneMTU to a different value", func() {
		Expect(patchControlPlaneMTU(newMTU)).To(Succeed())

		current, _, _, err := getControlPlaneMTU()
		Expect(err).NotTo(HaveOccurred())
		Expect(current).To(Equal(newMTU), "DPFOperatorConfig should reflect the new controlPlaneMTU")
	})

	// ── Recreate DPUDeployment so the new MTU takes effect on provisioning ──

	It("should recreate the DPUDeployment", func() {
		recreateDPUDeploymentFromBackup(dpuDeploymentBackup)
	})

	It("should recover the DPU deployment and networking after recreation with the new MTU", func() {
		waitForClusterHealthAfterDPUReprovisioning()
	})

	// ── Step 2: verify the new MTU propagated to downstream resources ──────

	It("should deploy workload pods", func() {
		Expect(dpuHostWorkers).NotTo(BeEmpty(), "no DPU-enabled host worker nodes discovered")
		manifestBytes := scaleWorkloadReplicas(manifests.WorkloadManifestBytes(), len(dpuHostWorkers))

		By("Applying workload manifests to management cluster")
		Expect(utils.ApplyManifests(ctx, mgmtClient, manifestBytes)).To(Succeed(),
			"failed to apply workload manifests")

		By("Waiting for all workload deployments to be ready")
		Expect(utils.WaitForDeployments(ctx, mgmtClient, cfg.WorkloadNamespace, 5*time.Minute)).To(Succeed(),
			"workload deployments not ready")
	})

	It("should discover workload pods", func() {
		Eventually(func(g Gomega) {
			pods, err := discoverWorkloadPods(ctx, mgmtClient, cfg.WorkloadNamespace, dpuHostWorkers)
			g.Expect(err).NotTo(HaveOccurred())
			workloadPods = pods
		}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())
	})

	It("should have the host-side OOB bridge on each DPU host worker node reflect the new controlPlaneMTU", func() {
		Expect(workloadPods).NotTo(BeNil(), "workload pods not discovered")
		Expect(workloadPods.HostNetWorkers).NotTo(BeEmpty(), "no sriov-test-worker-hostnetwork pods discovered")

		for _, hnw := range workloadPods.HostNetWorkers {
			mtu, err := getInterfaceMTU(ctx, mgmtConfig, mgmtClientset, cfg.WorkloadNamespace,
				hnw.Name, workloadContainerName, hostOOBBridgeName)
			Expect(err).NotTo(HaveOccurred())
			By(fmt.Sprintf("Checking %s MTU via hostNetwork pod %s", hostOOBBridgeName, hnw.Name))
			GinkgoWriter.Printf("Pod %s (node %s) %s MTU=%d (new controlPlaneMTU=%d)\n",
				hnw.Name, hnw.Spec.NodeName, hostOOBBridgeName, mtu, newMTU)

			Expect(mtu).To(Equal(newMTU),
				"%s MTU on DPU host worker node %s should equal the new controlPlaneMTU", hostOOBBridgeName, hnw.Spec.NodeName)
		}
	})

	It("should have br-comm-ch on each DPU node reflect the new controlPlaneMTU", func() {
		Expect(dpuWorkers).NotTo(BeEmpty(), "no DPU worker nodes discovered")

		for _, node := range dpuWorkers {
			By(fmt.Sprintf("Checking %s MTU on DPU node %s", dpuOOBBridgeName, node.Name))
			pod, err := findOVNNodePodOnNode(node.Name)
			Expect(err).NotTo(HaveOccurred())
			Expect(pod).NotTo(BeNil(), "no OVN node pod found on DPU worker node %s", node.Name)

			mtu, err := getInterfaceMTU(ctx, hostedConfig, hostedClientset, pod.Namespace, pod.Name, ovnNodeContainerName, dpuOOBBridgeName)
			Expect(err).NotTo(HaveOccurred())
			GinkgoWriter.Printf("Node %s %s MTU=%d (new controlPlaneMTU=%d)\n", node.Name, dpuOOBBridgeName, mtu, newMTU)

			Expect(mtu).To(Equal(newMTU),
				"%s MTU on DPU node %s should equal the new controlPlaneMTU", dpuOOBBridgeName, node.Name)
		}
	})

})

// getControlPlaneMTU reads the live DPFOperatorConfig and returns its
// spec.networking.controlPlaneMTU, falling back to the CRD default if unset.
// The boolean results preserve whether the fields were originally absent.
func getControlPlaneMTU() (int, bool, bool, error) {
	dpfConfig := &operatorv1.DPFOperatorConfig{}
	if err := mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: dpfe2e.DPFOperatorSystemNamespace,
		Name:      dpfe2e.ConfigName,
	}, dpfConfig); err != nil {
		return 0, false, false, fmt.Errorf("getting DPFOperatorConfig: %w", err)
	}
	if dpfConfig.Spec.Networking == nil {
		return defaultControlPlaneMTU, true, true, nil
	}
	if dpfConfig.Spec.Networking.ControlPlaneMTU == nil {
		return defaultControlPlaneMTU, false, true, nil
	}
	return *dpfConfig.Spec.Networking.ControlPlaneMTU, false, false, nil
}

// patchControlPlaneMTU reads the live DPFOperatorConfig, sets
// spec.networking.controlPlaneMTU to mtu, and updates the resource.
func patchControlPlaneMTU(mtu int) error {
	dpfConfig := &operatorv1.DPFOperatorConfig{}
	if err := mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: dpfe2e.DPFOperatorSystemNamespace,
		Name:      dpfe2e.ConfigName,
	}, dpfConfig); err != nil {
		return fmt.Errorf("getting DPFOperatorConfig: %w", err)
	}

	if dpfConfig.Spec.Networking == nil {
		dpfConfig.Spec.Networking = &operatorv1.Networking{}
	}
	dpfConfig.Spec.Networking.ControlPlaneMTU = &mtu

	if err := mgmtClient.Update(ctx, dpfConfig); err != nil {
		return fmt.Errorf("updating DPFOperatorConfig controlPlaneMTU to %d: %w", mtu, err)
	}
	return nil
}

// restoreControlPlaneMTU restores the original presence or absence of the
// networking and controlPlaneMTU fields, rather than only restoring the
// effective MTU value.
func restoreControlPlaneMTU(mtu int, networkingWasNil, controlPlaneMTUWasNil bool) error {
	dpfConfig := &operatorv1.DPFOperatorConfig{}
	if err := mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: dpfe2e.DPFOperatorSystemNamespace,
		Name:      dpfe2e.ConfigName,
	}, dpfConfig); err != nil {
		return fmt.Errorf("getting DPFOperatorConfig: %w", err)
	}

	if networkingWasNil {
		dpfConfig.Spec.Networking = nil
	} else {
		if dpfConfig.Spec.Networking == nil {
			dpfConfig.Spec.Networking = &operatorv1.Networking{}
		}
		if controlPlaneMTUWasNil {
			dpfConfig.Spec.Networking.ControlPlaneMTU = nil
		} else {
			dpfConfig.Spec.Networking.ControlPlaneMTU = &mtu
		}
	}

	if err := mgmtClient.Update(ctx, dpfConfig); err != nil {
		return fmt.Errorf("restoring DPFOperatorConfig controlPlaneMTU: %w", err)
	}
	return nil
}

// toggleMTU returns a different valid MTU value than current: 1500 if
// current is 9000, otherwise 9000. Mirrors the two NODES_MTU values
// supported by this repo's deployment scripts (scripts/env.sh validate_mtu).
func toggleMTU(current int) int {
	if current == 9000 {
		return 1500
	}
	return 9000
}
