package e2e

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	operatorv1 "github.com/nvidia/doca-platform/api/operator/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/manifests"
	"github.com/openshift-dpf/test/utils"
)

// ovnNodeComponentLabel/Value identify the "ovn" DPUService's per-node pod
// (a DaemonSet running on every DPU worker node in the hosted cluster). This
// pod runs with hostNetwork=true, so its "doca-ovnkube-controller" container
// can see the host's br-comm-ch bridge -- the DPU-side out-of-band bridge
// whose MTU is driven by DPFOperatorConfig.spec.networking.controlPlaneMTU.
//
// controlPlaneMTU governs the out-of-band "management network" only: the
// br-dpu bridge on the DPU-enabled host worker node (management cluster
// side) and its counterpart br-comm-ch bridge on the DPU node (hosted
// cluster side). It does NOT affect the high-speed OVN-Kubernetes data path
// (e.g. a workload pod's primary eth0 interface) -- that tracks
// highSpeedMTU instead, which this test leaves untouched.
const (
	ovnNodeComponentLabel      = "app.kubernetes.io/component"
	ovnNodeComponentLabelValue = "ovnkube-node"
	ovnNodeContainerName       = "doca-ovnkube-controller"
	dpuOOBBridgeName           = "br-comm-ch"
	hostOOBBridgeName          = "br-dpu"
	workloadContainerName      = "nginx"

	// defaultControlPlaneMTU mirrors the CRD's +kubebuilder:default for
	// Networking.ControlPlaneMTU, used when the field is unset.
	defaultControlPlaneMTU = 1500
)

// mtuLineRegexp matches the "mtu <N>" token in `ip link show` output.
var mtuLineRegexp = regexp.MustCompile(`\bmtu\s+(\d+)\b`)

// TC-MTU-003: Change ControlplaneMTU Before DPUDeployment
//
// Deletes the existing DPUDeployment to reach a "no DPUDeployment" initial
// state, changes DPFOperatorConfig.spec.networking.controlPlaneMTU to a
// different value, recreates the DPUDeployment so the new MTU takes effect
// on provisioning, and verifies the new MTU propagated to the out-of-band
// management network: the br-dpu bridge on the DPU host worker node
// (management cluster) and the br-comm-ch bridge on the DPU node (hosted
// cluster). The original controlPlaneMTU and DPUDeployment are restored at
// the end.
var _ = Describe("TC-MTU-003: Change ControlplaneMTU Before DPUDeployment", Label("mtu", "mtu-controlplane"), Ordered, func() {
	var (
		dpuDeploymentBackup *dpuservicev1.DPUDeployment
		originalMTU         int
		newMTU              int
		workloadPods        *WorkloadPods
	)

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available — skipping TC-MTU-003")
		}

		// Safety net mirroring the pattern in dpuservice_hbn_update_test.go:
		// if a later spec fails or is skipped, restore controlPlaneMTU and
		// the DPUDeployment so other tests sharing the cluster are not left
		// in a half-changed state. Runs once after the whole Ordered
		// container completes (AfterAll semantics), and is idempotent.
		DeferCleanup(func() {
			if originalMTU == 0 {
				return
			}
			current, err := getControlPlaneMTU()
			if err != nil {
				return
			}
			if current != originalMTU {
				By(fmt.Sprintf("Cleanup: restoring controlPlaneMTU %d -> %d", current, originalMTU))
				if err := patchControlPlaneMTU(originalMTU); err != nil {
					return
				}
			}
			ensureDPUDeploymentMatches(dpuDeploymentBackup)
		})
	})

	// ── Pre-conditions ──────────────────────────────────────────────────────

	It("pre-condition: should have a DPUDeployment in Ready state", func() {
		dpuDeployment := getDPUDeployment()
		Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
			"DPUDeployment must be Ready before MTU change test")
		dpuDeploymentBackup = dpuDeployment.DeepCopy()
	})

	It("pre-condition: should read current controlPlaneMTU and compute a different value", func() {
		var err error
		originalMTU, err = getControlPlaneMTU()
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

		current, err := getControlPlaneMTU()
		Expect(err).NotTo(HaveOccurred())
		Expect(current).To(Equal(newMTU), "DPFOperatorConfig should reflect the new controlPlaneMTU")
	})

	// ── Recreate DPUDeployment so the new MTU takes effect on provisioning ──

	It("should recreate the DPUDeployment", func() {
		recreateDPUDeploymentFromBackup(dpuDeploymentBackup)
	})

	It("should reach Ready state after recreation with the new MTU", func() {
		waitForDPUDeploymentReady()
	})

	It("should have all DPU objects in Ready phase after reprovisioning", func() {
		waitForDPUObjectsReady(len(dpuHostWorkers))
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

	It("should have br-dpu on each DPU host worker node reflect the new controlPlaneMTU", func() {
		Expect(workloadPods).NotTo(BeNil(), "workload pods not discovered")
		Expect(workloadPods.HostNetWorkers).NotTo(BeEmpty(), "no sriov-test-worker-hostnetwork pods discovered")

		for _, hnw := range workloadPods.HostNetWorkers {
			By(fmt.Sprintf("Checking %s MTU via hostNetwork pod %s", hostOOBBridgeName, hnw.Name))
			mtu, err := getInterfaceMTU(ctx, mgmtConfig, mgmtClientset, cfg.WorkloadNamespace, hnw.Name, workloadContainerName, hostOOBBridgeName)
			Expect(err).NotTo(HaveOccurred())
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

	// ── Restore original state ──────────────────────────────────────────────

	It("should restore original controlPlaneMTU", func() {
		Expect(patchControlPlaneMTU(originalMTU)).To(Succeed())

		current, err := getControlPlaneMTU()
		Expect(err).NotTo(HaveOccurred())
		Expect(current).To(Equal(originalMTU), "DPFOperatorConfig should reflect the restored controlPlaneMTU")
	})

	It("should delete and recreate the DPUDeployment with the original MTU", func() {
		deleteDPUDeploymentAndWait()
		recreateDPUDeploymentFromBackup(dpuDeploymentBackup)
		waitForDPUDeploymentReady()
		waitForDPUObjectsReady(len(dpuHostWorkers))
	})

	It("should have a healthy cluster after MTU restoration", func() {
		waitForClusterHealth()
	})
})

// getControlPlaneMTU reads the live DPFOperatorConfig and returns its
// spec.networking.controlPlaneMTU, falling back to the CRD default if unset.
func getControlPlaneMTU() (int, error) {
	dpfConfig := &operatorv1.DPFOperatorConfig{}
	if err := mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: dpfe2e.DPFOperatorSystemNamespace,
		Name:      dpfe2e.ConfigName,
	}, dpfConfig); err != nil {
		return 0, fmt.Errorf("getting DPFOperatorConfig: %w", err)
	}
	if dpfConfig.Spec.Networking == nil || dpfConfig.Spec.Networking.ControlPlaneMTU == nil {
		return defaultControlPlaneMTU, nil
	}
	return *dpfConfig.Spec.Networking.ControlPlaneMTU, nil
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

// toggleMTU returns a different valid MTU value than current: 1500 if
// current is 9000, otherwise 9000. Mirrors the two NODES_MTU values
// supported by this repo's deployment scripts (scripts/env.sh validate_mtu).
func toggleMTU(current int) int {
	if current == 9000 {
		return 1500
	}
	return 9000
}

// deleteDPUDeploymentAndWait deletes the configured DPUDeployment and waits
// for it to be fully removed. Mirrors dpudeployment_lifecycle_test.go.
func deleteDPUDeploymentAndWait() {
	dpuDeployment := &dpuservicev1.DPUDeployment{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: cfg.DPFNamespace,
			Name:      cfg.DPUDeploymentName,
		},
	}
	err := mgmtClient.Delete(ctx, dpuDeployment)
	Expect(client.IgnoreNotFound(err)).To(Succeed(), "failed to delete DPUDeployment")

	By("Waiting for DPUDeployment to be fully removed")
	Eventually(func(g Gomega) {
		err := mgmtClient.Get(ctx, client.ObjectKeyFromObject(dpuDeployment), dpuDeployment)
		g.Expect(apierrors.IsNotFound(err)).To(BeTrue(),
			"DPUDeployment should be fully deleted, got: %v", err)
	}).WithTimeout(10 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())

	GinkgoWriter.Printf("DPUDeployment %s deleted successfully\n", cfg.DPUDeploymentName)
}

// recreateDPUDeploymentFromBackup creates a new DPUDeployment using the
// ObjectMeta and Spec captured from backup. Mirrors
// dpudeployment_lifecycle_test.go.
func recreateDPUDeploymentFromBackup(backup *dpuservicev1.DPUDeployment) {
	Expect(backup).NotTo(BeNil(), "DPUDeployment backup should have been captured")

	newDeployment := &dpuservicev1.DPUDeployment{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:   backup.Namespace,
			Name:        backup.Name,
			Labels:      backup.Labels,
			Annotations: backup.Annotations,
		},
		Spec: backup.Spec,
	}

	Expect(mgmtClient.Create(ctx, newDeployment)).To(Succeed(),
		"failed to recreate DPUDeployment")
	GinkgoWriter.Printf("DPUDeployment %s recreated\n", newDeployment.Name)
}

// ensureDPUDeploymentMatches recreates the DPUDeployment from backup if it
// is currently missing, used only from the BeforeAll DeferCleanup safety net.
func ensureDPUDeploymentMatches(backup *dpuservicev1.DPUDeployment) {
	if backup == nil {
		return
	}
	existing := &dpuservicev1.DPUDeployment{}
	err := mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.DPFNamespace,
		Name:      cfg.DPUDeploymentName,
	}, existing)
	if err == nil {
		return
	}
	if !apierrors.IsNotFound(err) {
		return
	}
	By("Cleanup: recreating DPUDeployment from backup")
	newDeployment := &dpuservicev1.DPUDeployment{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:   backup.Namespace,
			Name:        backup.Name,
			Labels:      backup.Labels,
			Annotations: backup.Annotations,
		},
		Spec: backup.Spec,
	}
	_ = mgmtClient.Create(ctx, newDeployment)
}

// waitForDPUDeploymentReady polls the configured DPUDeployment until its
// Ready condition is True. Mirrors dpudeployment_lifecycle_test.go.
func waitForDPUDeploymentReady() {
	By("Waiting for DPUDeployment to become Ready")
	Eventually(func(g Gomega) {
		dpuDeployment := &dpuservicev1.DPUDeployment{}
		g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: cfg.DPFNamespace,
			Name:      cfg.DPUDeploymentName,
		}, dpuDeployment)).To(Succeed())
		g.Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
			"DPUDeployment should have Ready=True condition")
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(5 * time.Second).Should(Succeed())

	GinkgoWriter.Printf("DPUDeployment %s is Ready\n", cfg.DPUDeploymentName)
}

// waitForDPUObjectsReady waits until at least expectedDPUs DPU objects reach
// the Ready phase. Mirrors dpudeployment_lifecycle_test.go.
func waitForDPUObjectsReady(expectedDPUs int) {
	By(fmt.Sprintf("Waiting for %d DPU objects to reach Ready phase", expectedDPUs))
	Eventually(func(g Gomega) {
		dpuList := &provisioningv1.DPUList{}
		g.Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())
		g.Expect(len(dpuList.Items)).To(BeNumerically(">=", expectedDPUs),
			"Expected at least %d DPU objects, got %d", expectedDPUs, len(dpuList.Items))

		readyCount := 0
		for _, dpu := range dpuList.Items {
			if dpu.Status.Phase == provisioningv1.DPUReady {
				readyCount++
			}
		}
		g.Expect(readyCount).To(BeNumerically(">=", expectedDPUs),
			"Expected %d DPUs in Ready phase, got %d (total: %d)",
			expectedDPUs, readyCount, len(dpuList.Items))
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

	GinkgoWriter.Printf("All %d DPU objects are in Ready phase\n", expectedDPUs)
}

// findOVNNodePodOnNode returns the per-node "ovn" DPUService pod
// (ovnkube-node component) scheduled on the given hosted-cluster node.
func findOVNNodePodOnNode(nodeName string) (*corev1.Pod, error) {
	podList := &corev1.PodList{}
	if err := hostedClient.List(ctx, podList,
		client.InNamespace(cfg.DPFNamespace),
		client.MatchingLabels{ovnNodeComponentLabel: ovnNodeComponentLabelValue},
	); err != nil {
		return nil, fmt.Errorf("listing OVN node pods in %s: %w", cfg.DPFNamespace, err)
	}
	for i := range podList.Items {
		if podList.Items[i].Spec.NodeName == nodeName {
			return &podList.Items[i], nil
		}
	}
	return nil, nil
}

// getInterfaceMTU execs `ip link show <iface>` in the given pod/container
// and parses the MTU value from the output.
func getInterfaceMTU(ctx context.Context, restCfg *rest.Config, cs *kubernetes.Clientset, namespace, podName, containerName, iface string) (int, error) {
	result, err := utils.ExecInPod(ctx, restCfg, cs, namespace, podName, containerName, []string{
		"ip", "link", "show", iface,
	})
	if err != nil {
		return 0, fmt.Errorf("getting %s MTU on pod %s: %w", iface, podName, err)
	}

	match := mtuLineRegexp.FindStringSubmatch(result.Stdout)
	if match == nil {
		return 0, fmt.Errorf("could not parse MTU for interface %s on pod %s from output: %s", iface, podName, result.Stdout)
	}
	mtu, err := strconv.Atoi(match[1])
	if err != nil {
		return 0, fmt.Errorf("parsing MTU value %q for interface %s: %w", match[1], iface, err)
	}
	return mtu, nil
}
