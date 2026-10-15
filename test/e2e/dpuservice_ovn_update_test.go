package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	ovnDPUServiceConfigurationName = "ovn"
	ovnDeploymentServiceName       = "ovn"
)

// TC-SVC-002: Update OVN DPUService
//
// Updates the OVN DPUServiceConfiguration, verifies that the DPUDeployment
// creates a new Ready OVN DPUService and that the OVN-K pods are replaced with
// the new configuration, then restores the original configuration and checks
// the restored service setting, pod readiness, and cluster health.
var _ = Describe("TC-SVC-002: Update OVN DPUService", Label("dpuservice", "update-ovn-dpuservice"), Ordered, func() {
	var (
		originalOVNHelmValues   []byte
		originalOVNEnableEgress string
		updatedOVNEnableEgress  string
		originalCaptured        bool
		updateAttempted         bool

		updateServiceUIDs map[types.UID]bool
		preUpdatePodUIDs  map[string]map[types.UID]bool
		updatedPodUIDs    map[string]map[types.UID]bool
	)

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available — skipping TC-SVC-002")
		}
	})

	AfterAll(func() {
		if !originalCaptured {
			return
		}

		configuration := &dpuservicev1.DPUServiceConfiguration{}
		configurationErr := mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: cfg.DPFNamespace,
			Name:      ovnDPUServiceConfigurationName,
		}, configuration)
		if configurationErr == nil && configuration.Spec.ServiceConfiguration.HelmChart.Values != nil &&
			bytes.Equal(configuration.Spec.ServiceConfiguration.HelmChart.Values.Raw, originalOVNHelmValues) && !updateAttempted {
			// The update was never attempted, so there is no rollout to restore or verify.
			return
		}
		if configurationErr != nil {
			GinkgoWriter.Printf("Could not read OVN DPUServiceConfiguration before restore; will retry while restoring: %v\n", configurationErr)
		}

		restorePodUIDs, podSnapshotErr := listOVNKPodUIDsByNode()
		if podSnapshotErr != nil {
			GinkgoWriter.Printf("Could not snapshot OVN-K pod UIDs before restore: %v\n", podSnapshotErr)
		}

		By("AfterAll: restoring the original OVN Helm values")
		Eventually(func(g Gomega) {
			g.Expect(restoreOVNHelmValues(originalOVNHelmValues)).To(Succeed())
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(10 * time.Second).Should(Succeed())

		configuration = getOVNDPUServiceConfiguration()
		Expect(string(configuration.Spec.ServiceConfiguration.HelmChart.Values.Raw)).To(
			MatchJSON(string(originalOVNHelmValues)),
			"AfterAll: OVN Helm values should match the original configuration")

		waitForOVNConfigurationAndPodsRestored(originalOVNEnableEgress, preUpdatePodUIDs, updatedPodUIDs, restorePodUIDs)
		waitForClusterHealth()

		if podSnapshotErr != nil {
			Expect(fmt.Errorf("OVN-K pod snapshot: %v", podSnapshotErr)).NotTo(HaveOccurred(),
				"could not verify OVN-K pod replacement checks during restore")
		}
	})

	It("pre-condition: should have DPUDeployment in Ready state", func() {
		dpuDeployment := getDPUDeployment()
		Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
			"DPUDeployment must be Ready before OVN update test")
	})

	It("pre-condition: should have an OVN DPUServiceConfiguration that can be changed", func() {
		configuration := getOVNDPUServiceConfiguration()
		Expect(configuration.Spec.ServiceConfiguration.HelmChart.Values).NotTo(BeNil(),
			"OVN DPUServiceConfiguration should have Helm values")

		originalOVNHelmValues = append([]byte(nil), configuration.Spec.ServiceConfiguration.HelmChart.Values.Raw...)
		originalCaptured = true
	})

	It("pre-condition: should have Ready OVN DPUService revisions", func() {
		services := listOVNDPUServiceRevisions()
		Expect(services).NotTo(BeEmpty(), "no OVN DPUService revisions found")
		for _, service := range services {
			Expect(isReady(service.Status.Conditions)).To(BeTrue(),
				"OVN DPUService %s should be Ready before update", service.Name)
		}

		// The DPUService may render a Helm chart default that is absent from the
		// DPUServiceConfiguration. Use the newest Ready revision as the effective
		// current setting so the test always flips what is running.
		currentService := &services[0]
		for i := 1; i < len(services); i++ {
			if services[i].CreationTimestamp.After(currentService.CreationTimestamp.Time) {
				currentService = &services[i]
			}
		}
		value, found, err := ovnEnableEgressIPFromDPUService(currentService)
		Expect(err).NotTo(HaveOccurred())
		originalOVNEnableEgress = effectiveOVNEnableEgressIP(value, found)

		// OVN-K defaults an omitted or empty enable flag to false. Always change
		// the effective setting and restore the original Helm values afterward.
		updatedOVNEnableEgress = "true"
		if originalOVNEnableEgress == "true" {
			updatedOVNEnableEgress = "false"
		}
		Expect(updatedOVNEnableEgress).NotTo(Equal(originalOVNEnableEgress),
			"OVN enableEgressIP update must change the effective value")
	})

	It("pre-condition: should have Ready OVN-K pods on every DPU worker", func() {
		waitForOVNKPodsReady(dpuWorkers)
		podUIDs := ovnKPodUIDsByNode()
		for _, node := range dpuWorkers {
			Expect(podUIDs[node.Name]).NotTo(BeEmpty(),
				"no OVN-K pod found on DPU worker %s", node.Name)
		}
	})

	It("pre-condition: should have a healthy cluster before OVN update", func() {
		waitForClusterHealth()
	})

	It("should update enableEgressIP in the OVN DPUServiceConfiguration", func() {
		updateServiceUIDs = dpuServiceUIDs(listOVNDPUServiceRevisions())
		preUpdatePodUIDs = ovnKPodUIDsByNode()
		Expect(updateServiceUIDs).NotTo(BeEmpty(), "no OVN DPUService revisions found before update")

		updateAttempted = true
		By(fmt.Sprintf("Patching OVN DPUServiceConfiguration global.enableEgressIP to %q", updatedOVNEnableEgress))
		Expect(patchOVNEnableEgressIP(updatedOVNEnableEgress)).To(Succeed())
	})

	It("should create a Ready OVN DPUService with the updated setting", func() {
		waitForOVNServiceRevision(updateServiceUIDs, updatedOVNEnableEgress)
	})

	It("should replace OVN-K pods after the updated DPUService rolls out", func() {
		waitForOVNKPodsReplaced(preUpdatePodUIDs)
		updatedPodUIDs = ovnKPodUIDsByNode()
	})

	It("should verify the updated OVN configuration", func() {
		configuration := getOVNDPUServiceConfiguration()
		value, found, err := ovnEnableEgressIP(configuration)
		Expect(err).NotTo(HaveOccurred())
		Expect(found).To(BeTrue())
		Expect(value).To(Equal(updatedOVNEnableEgress),
			"OVN configuration should contain enableEgressIP=%q", updatedOVNEnableEgress)

		services := listOVNDPUServiceRevisions()
		foundUpdated := false
		for _, service := range services {
			value, found, err := ovnEnableEgressIPFromDPUService(&service)
			Expect(err).NotTo(HaveOccurred())
			if found && value == updatedOVNEnableEgress {
				foundUpdated = true
				Expect(isReady(service.Status.Conditions)).To(BeTrue(),
					"updated OVN DPUService %s should be Ready", service.Name)
			}
		}
		Expect(foundUpdated).To(BeTrue(), "no OVN DPUService rendered with enableEgressIP=%q", updatedOVNEnableEgress)
	})

	It("should have a healthy cluster after the OVN update", func() {
		waitForOVNKPodsReady(dpuWorkers)
		waitForClusterHealth()
	})
})

// getOVNDPUServiceConfiguration fetches the OVN service configuration from the management cluster.
func getOVNDPUServiceConfiguration() *dpuservicev1.DPUServiceConfiguration {
	configuration := &dpuservicev1.DPUServiceConfiguration{}
	Expect(mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.DPFNamespace,
		Name:      ovnDPUServiceConfigurationName,
	}, configuration)).To(Succeed(), "failed to get OVN DPUServiceConfiguration")
	return configuration
}

// listOVNDPUServiceRevisions returns generated OVN services owned by the configured DPUDeployment.
func listOVNDPUServiceRevisions() []dpuservicev1.DPUService {
	services, err := listDPUServiceRevisions(ctx, mgmtClient, cfg.DPFNamespace, cfg.DPUDeploymentName, ovnDeploymentServiceName)
	Expect(err).NotTo(HaveOccurred())
	return services
}

// ovnEnableEgressIP reads the configured global.enableEgressIP string and reports whether it is set.
func ovnEnableEgressIP(configuration *dpuservicev1.DPUServiceConfiguration) (string, bool, error) {
	values, err := decodeHelmValues(configuration)
	if err != nil {
		return "", false, err
	}
	return ovnEnableEgressIPFromValues(values)
}

// ovnEnableEgressIPFromDPUService reads global.enableEgressIP from a generated DPUService.
func ovnEnableEgressIPFromDPUService(service *dpuservicev1.DPUService) (string, bool, error) {
	if service.Spec.HelmChart.Values == nil {
		return "", false, fmt.Errorf("DPUService %s has no Helm values", service.Name)
	}

	values := &dpuservicev1.DPUServiceConfiguration{}
	values.Spec.ServiceConfiguration.HelmChart.Values = service.Spec.HelmChart.Values
	return ovnEnableEgressIP(values)
}

// ovnEnableEgressIPFromValues reads global.enableEgressIP from decoded Helm values.
func ovnEnableEgressIPFromValues(values map[string]interface{}) (string, bool, error) {
	global, ok := values["global"].(map[string]interface{})
	if !ok {
		return "", false, fmt.Errorf("OVN Helm values missing global map")
	}
	value, found := global["enableEgressIP"]
	if !found {
		return "", false, nil
	}
	switch value := value.(type) {
	case string:
		return value, true, nil
	case bool:
		return strconv.FormatBool(value), true, nil
	default:
		return "", true, fmt.Errorf("OVN global.enableEgressIP has type %T, expected string or bool", value)
	}
}

// effectiveOVNEnableEgressIP treats an omitted or empty Helm value as OVN-K's false default.
func effectiveOVNEnableEgressIP(value string, found bool) string {
	if !found || value == "" {
		return "false"
	}
	return value
}

// waitForOVNConfigurationAndPodsRestored waits for the original service revision
// to be active and Ready, conflicting revisions to be paused, and temporary
// rollout pods to be gone from every DPU worker.
func waitForOVNConfigurationAndPodsRestored(
	expectedEnableEgressIP string,
	preUpdatePodUIDs, knownUpdatedPodUIDs, restorePodUIDs map[string]map[types.UID]bool,
) {
	updatedPodUIDsToRemove := make(map[types.UID]bool)
	for _, uids := range knownUpdatedPodUIDs {
		for uid := range uids {
			updatedPodUIDsToRemove[uid] = true
		}
	}
	for _, uids := range podUIDsAbsentFromBaseline(preUpdatePodUIDs, restorePodUIDs) {
		for uid := range uids {
			updatedPodUIDsToRemove[uid] = true
		}
	}

	By(fmt.Sprintf("Waiting for the active OVN DPUService and pods to restore enableEgressIP=%q", expectedEnableEgressIP))
	Eventually(func(g Gomega) {
		services, err := listDPUServiceRevisions(
			ctx, mgmtClient, cfg.DPFNamespace, cfg.DPUDeploymentName, ovnDeploymentServiceName)
		g.Expect(err).NotTo(HaveOccurred())

		foundActiveReadyExpected := false
		foundActiveConflictingRevision := false
		for _, service := range services {
			value, found, err := ovnEnableEgressIPFromDPUService(&service)
			g.Expect(err).NotTo(HaveOccurred())
			if service.IsPaused() {
				continue
			}

			if effectiveOVNEnableEgressIP(value, found) != expectedEnableEgressIP {
				foundActiveConflictingRevision = true
				continue
			}

			if service.Status.ObservedGeneration == service.Generation && isReady(service.Status.Conditions) {
				foundActiveReadyExpected = true
			}
		}

		pods := &corev1.PodList{}
		g.Expect(hostedClient.List(ctx, pods,
			client.InNamespace(cfg.DPFNamespace),
			client.MatchingLabels{"app.kubernetes.io/component": ovnKubeNodeComponent},
		)).To(Succeed())

		// The update may still create pods after the pre-restore snapshot. Keep
		// collecting non-baseline UIDs for as long as an updated revision is
		// active, then require all of those pods to disappear.
		if foundActiveConflictingRevision {
			newPodUIDs := podUIDsAbsentFromBaseline(preUpdatePodUIDs, podUIDsByNode(pods.Items))
			for _, uids := range newPodUIDs {
				for uid := range uids {
					updatedPodUIDsToRemove[uid] = true
				}
			}
		}

		deployment := &dpuservicev1.DPUDeployment{}
		g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: cfg.DPFNamespace,
			Name:      cfg.DPUDeploymentName,
		}, deployment)).To(Succeed())
		g.Expect(deployment.Status.ObservedGeneration).To(Equal(deployment.Generation),
			"DPUDeployment should have observed its current generation after restore")
		g.Expect(isReady(deployment.Status.Conditions)).To(BeTrue(),
			"DPUDeployment should be Ready after restoring OVN configuration")
		g.Expect(foundActiveReadyExpected).To(BeTrue(),
			"no active, current-generation Ready OVN DPUService rendered with enableEgressIP=%q", expectedEnableEgressIP)
		g.Expect(foundActiveConflictingRevision).To(BeFalse(),
			"an OVN DPUService with a conflicting enableEgressIP setting is still active")

		var podsToRemove []types.UID
		for i := range pods.Items {
			if updatedPodUIDsToRemove[pods.Items[i].UID] {
				podsToRemove = append(podsToRemove, pods.Items[i].UID)
			}
		}
		g.Expect(podsToRemove).To(BeEmpty(), "OVN-K pods from the temporary update revision should be gone")

		for _, node := range dpuWorkers {
			var readyPod bool
			for i := range pods.Items {
				pod := &pods.Items[i]
				if pod.Spec.NodeName != node.Name {
					continue
				}
				if updatedPodUIDsToRemove[pod.UID] {
					continue
				}
				if podIsReady(pod) {
					readyPod = true
				}
			}
			g.Expect(readyPod).To(BeTrue(),
				"DPU worker %s should have a Ready OVN-K pod after restore", node.Name)
		}
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(10 * time.Second).Should(Succeed())
}

// patchOVNEnableEgressIP updates global.enableEgressIP while preserving the other Helm values.
func patchOVNEnableEgressIP(value string) error {
	configuration := getOVNDPUServiceConfiguration()
	values, err := decodeHelmValues(configuration)
	if err != nil {
		return err
	}
	global, ok := values["global"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("OVN Helm values missing global map")
	}
	// This chart value is a string; write the same type used by the manual
	// DPUServiceConfiguration patch even if the original YAML used a boolean.
	global["enableEgressIP"] = value

	raw, err := json.Marshal(values)
	if err != nil {
		return fmt.Errorf("marshalling updated OVN Helm values: %w", err)
	}
	configuration.Spec.ServiceConfiguration.HelmChart.Values = &runtime.RawExtension{Raw: raw}
	return mgmtClient.Update(ctx, configuration)
}

// restoreOVNHelmValues applies the saved OVN Helm values if they are not already present.
func restoreOVNHelmValues(raw []byte) error {
	configuration := &dpuservicev1.DPUServiceConfiguration{}
	if err := mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.DPFNamespace,
		Name:      ovnDPUServiceConfigurationName,
	}, configuration); err != nil {
		return fmt.Errorf("getting OVN DPUServiceConfiguration for restore: %w", err)
	}
	if configuration.Spec.ServiceConfiguration.HelmChart.Values != nil &&
		bytes.Equal(configuration.Spec.ServiceConfiguration.HelmChart.Values.Raw, raw) {
		return nil
	}

	configuration.Spec.ServiceConfiguration.HelmChart.Values = &runtime.RawExtension{
		Raw: append([]byte(nil), raw...),
	}
	if err := mgmtClient.Update(ctx, configuration); err != nil {
		return fmt.Errorf("updating OVN DPUServiceConfiguration for restore: %w", err)
	}
	return nil
}

// ovnKPodUIDsByNode groups hosted OVN-K pod UIDs by their scheduled worker node.
func ovnKPodUIDsByNode() map[string]map[types.UID]bool {
	uids, err := listOVNKPodUIDsByNode()
	Expect(err).NotTo(HaveOccurred(), "failed to list OVN-K pods")
	return uids
}

// listOVNKPodUIDsByNode groups hosted OVN-K pod UIDs by node and returns list errors to the caller.
func listOVNKPodUIDsByNode() (map[string]map[types.UID]bool, error) {
	pods := &corev1.PodList{}
	if err := hostedClient.List(ctx, pods,
		client.InNamespace(cfg.DPFNamespace),
		client.MatchingLabels{"app.kubernetes.io/component": ovnKubeNodeComponent},
	); err != nil {
		return nil, fmt.Errorf("listing OVN-K pods: %w", err)
	}
	return podUIDsByNode(pods.Items), nil
}

// waitForOVNServiceRevision waits for a new Ready service revision with the expected setting.
func waitForOVNServiceRevision(previousServiceUIDs map[types.UID]bool, expectedEnableEgressIP string) {
	By("Waiting for a new Ready OVN DPUService revision")
	Eventually(func(g Gomega) {
		services, err := listDPUServiceRevisions(
			ctx, mgmtClient, cfg.DPFNamespace, cfg.DPUDeploymentName, ovnDeploymentServiceName)
		g.Expect(err).NotTo(HaveOccurred())
		var newServices []dpuservicev1.DPUService
		for _, service := range services {
			if previousServiceUIDs[service.UID] {
				continue
			}
			value, found, err := ovnEnableEgressIPFromDPUService(&service)
			g.Expect(err).NotTo(HaveOccurred())
			if effectiveOVNEnableEgressIP(value, found) == expectedEnableEgressIP {
				newServices = append(newServices, service)
			}
		}
		g.Expect(newServices).NotTo(BeEmpty(), "expected a new OVN DPUService revision")
		for _, service := range newServices {
			g.Expect(isReady(service.Status.Conditions)).To(BeTrue(),
				"OVN DPUService %s should be Ready", service.Name)
		}
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(10 * time.Second).Should(Succeed())
}

// waitForOVNKPodsReplaced waits for Ready pods and removal of every tracked OVN-K pod UID.
func waitForOVNKPodsReplaced(podUIDsToReplace map[string]map[types.UID]bool) {
	By("Waiting for tracked OVN-K pods to be removed and every DPU worker to have a Ready pod")
	Eventually(func(g Gomega) {
		pods := &corev1.PodList{}
		g.Expect(hostedClient.List(ctx, pods,
			client.InNamespace(cfg.DPFNamespace),
			client.MatchingLabels{"app.kubernetes.io/component": ovnKubeNodeComponent},
		)).To(Succeed())

		for _, node := range dpuWorkers {
			var replacementReady bool
			var previousPods []types.UID
			for i := range pods.Items {
				pod := &pods.Items[i]
				if pod.Spec.NodeName != node.Name {
					continue
				}
				if podUIDsToReplace[node.Name][pod.UID] {
					previousPods = append(previousPods, pod.UID)
					continue
				}
				if podIsReady(pod) {
					replacementReady = true
				}
			}
			g.Expect(previousPods).To(BeEmpty(),
				"DPU worker %s still has OVN-K pods that should have been replaced", node.Name)
			g.Expect(replacementReady).To(BeTrue(),
				"DPU worker %s should have a Ready OVN-K pod", node.Name)
		}
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(10 * time.Second).Should(Succeed())
}
