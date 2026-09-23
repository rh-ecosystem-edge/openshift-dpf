package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
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
// creates a new Ready OVN DPUService and that the OVN pods are replaced with
// the new configuration, then restores the original configuration and checks
// the same lifecycle again.
var _ = Describe("TC-SVC-002: Update OVN DPUService", Label("dpuservice", "update-ovn-dpuservice"), Ordered, func() {
	var (
		originalOVNHelmValues   []byte
		originalOVNEnableEgress string
		originalCaptured        bool

		updateServiceUIDs map[types.UID]bool
		updatePodUIDs     map[string]map[types.UID]bool
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

		configuration := getOVNDPUServiceConfiguration()
		if bytes.Equal(configuration.Spec.ServiceConfiguration.HelmChart.Values.Raw, originalOVNHelmValues) {
			return
		}

		restoreServiceUIDs := dpuServiceUIDs(listOVNDPUServiceRevisions())
		restorePodUIDs := ovnPodUIDsByNode()

		By("AfterAll: restoring the original OVN Helm values")
		Expect(restoreOVNHelmValues(originalOVNHelmValues)).To(Succeed())

		waitForOVNServiceRevision(restoreServiceUIDs, originalOVNEnableEgress)
		waitForOVNPodsReplaced(restorePodUIDs)

		configuration = getOVNDPUServiceConfiguration()
		Expect(string(configuration.Spec.ServiceConfiguration.HelmChart.Values.Raw)).To(
			MatchJSON(string(originalOVNHelmValues)),
			"AfterAll: OVN Helm values should match the original configuration")

		verifyOVNServiceConfiguration(originalOVNEnableEgress)
		waitForOVNKPodsReady(dpuWorkers)
		waitForClusterHealth()
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

		value, found, err := ovnEnableEgressIP(configuration)
		Expect(err).NotTo(HaveOccurred())
		if found {
			originalOVNEnableEgress = value
		}
		Expect(found && value == "true").To(BeFalse(),
			"OVN enableEgressIP must not already be \"true\" before the update")
	})

	It("pre-condition: should have Ready OVN DPUService revisions", func() {
		services := listOVNDPUServiceRevisions()
		Expect(services).NotTo(BeEmpty(), "no OVN DPUService revisions found")
		for _, service := range services {
			Expect(isReady(service.Status.Conditions)).To(BeTrue(),
				"OVN DPUService %s should be Ready before update", service.Name)
		}
	})

	It("pre-condition: should have Ready OVN pods on every DPU worker", func() {
		waitForOVNKPodsReady(dpuWorkers)
		podUIDs := ovnPodUIDsByNode()
		for _, node := range dpuWorkers {
			Expect(podUIDs[node.Name]).NotTo(BeEmpty(),
				"no OVN pod found on DPU worker %s", node.Name)
		}
	})

	It("should update enableEgressIP in the OVN DPUServiceConfiguration", func() {
		updateServiceUIDs = dpuServiceUIDs(listOVNDPUServiceRevisions())
		updatePodUIDs = ovnPodUIDsByNode()
		Expect(updateServiceUIDs).NotTo(BeEmpty(), "no OVN DPUService revisions found before update")

		By("Patching OVN DPUServiceConfiguration global.enableEgressIP to \"true\"")
		Expect(patchOVNEnableEgressIP("true")).To(Succeed())
	})

	It("should create a Ready OVN DPUService with the updated setting", func() {
		waitForOVNServiceRevision(updateServiceUIDs, "true")
	})

	It("should replace OVN pods after the updated DPUService rolls out", func() {
		waitForOVNPodsReplaced(updatePodUIDs)
	})

	It("should verify the updated OVN configuration", func() {
		configuration := getOVNDPUServiceConfiguration()
		value, found, err := ovnEnableEgressIP(configuration)
		Expect(err).NotTo(HaveOccurred())
		Expect(found).To(BeTrue())
		Expect(value).To(Equal("true"), "OVN configuration should contain enableEgressIP=\"true\"")

		services := listOVNDPUServiceRevisions()
		foundUpdated := false
		for _, service := range services {
			value, found, err := ovnEnableEgressIPFromDPUService(&service)
			Expect(err).NotTo(HaveOccurred())
			if found && value == "true" {
				foundUpdated = true
				Expect(isReady(service.Status.Conditions)).To(BeTrue(),
					"updated OVN DPUService %s should be Ready", service.Name)
			}
		}
		Expect(foundUpdated).To(BeTrue(), "no OVN DPUService rendered with enableEgressIP=\"true\"")
	})

	It("should have a healthy cluster after the OVN update", func() {
		waitForOVNKPodsReady(dpuWorkers)
		waitForClusterHealth()
	})
})

func getOVNDPUServiceConfiguration() *dpuservicev1.DPUServiceConfiguration {
	configuration := &dpuservicev1.DPUServiceConfiguration{}
	Expect(mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.DPFNamespace,
		Name:      ovnDPUServiceConfigurationName,
	}, configuration)).To(Succeed(), "failed to get OVN DPUServiceConfiguration")
	return configuration
}

func listOVNDPUServiceRevisions() []dpuservicev1.DPUService {
	services, err := listDPUServiceRevisions(ctx, mgmtClient, cfg.DPFNamespace, cfg.DPUDeploymentName, ovnDeploymentServiceName)
	Expect(err).NotTo(HaveOccurred())
	return services
}

func ovnEnableEgressIP(configuration *dpuservicev1.DPUServiceConfiguration) (string, bool, error) {
	values, err := decodeHelmValues(configuration)
	if err != nil {
		return "", false, err
	}
	return ovnEnableEgressIPFromValues(values)
}

func ovnEnableEgressIPFromDPUService(service *dpuservicev1.DPUService) (string, bool, error) {
	if service.Spec.HelmChart.Values == nil {
		return "", false, fmt.Errorf("DPUService %s has no Helm values", service.Name)
	}

	values := &dpuservicev1.DPUServiceConfiguration{}
	values.Spec.ServiceConfiguration.HelmChart.Values = service.Spec.HelmChart.Values
	return ovnEnableEgressIP(values)
}

func ovnEnableEgressIPFromValues(values map[string]interface{}) (string, bool, error) {
	global, ok := values["global"].(map[string]interface{})
	if !ok {
		return "", false, fmt.Errorf("OVN Helm values missing global map")
	}
	value, found := global["enableEgressIP"]
	if !found {
		return "", false, nil
	}
	valueString, ok := value.(string)
	if !ok {
		return "", true, fmt.Errorf("OVN global.enableEgressIP has type %T, expected string", value)
	}
	return valueString, true, nil
}

func verifyOVNServiceConfiguration(expectedEnableEgressIP string) {
	services := listOVNDPUServiceRevisions()
	foundExpected := false
	for _, service := range services {
		value, found, err := ovnEnableEgressIPFromDPUService(&service)
		Expect(err).NotTo(HaveOccurred())
		if (found && value == expectedEnableEgressIP) || (!found && expectedEnableEgressIP == "") {
			foundExpected = true
			Expect(isReady(service.Status.Conditions)).To(BeTrue(),
				"OVN DPUService %s should be Ready with the expected configuration", service.Name)
		}
	}
	Expect(foundExpected).To(BeTrue(), "no OVN DPUService rendered with the expected configuration")
}

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
	global["enableEgressIP"] = value

	raw, err := json.Marshal(values)
	if err != nil {
		return fmt.Errorf("marshalling updated OVN Helm values: %w", err)
	}
	configuration.Spec.ServiceConfiguration.HelmChart.Values = &runtime.RawExtension{Raw: raw}
	return mgmtClient.Update(ctx, configuration)
}

func restoreOVNHelmValues(raw []byte) error {
	configuration := getOVNDPUServiceConfiguration()
	configuration.Spec.ServiceConfiguration.HelmChart.Values = &runtime.RawExtension{
		Raw: append([]byte(nil), raw...),
	}
	return mgmtClient.Update(ctx, configuration)
}

func ovnPodUIDsByNode() map[string]map[types.UID]bool {
	pods := &corev1.PodList{}
	Expect(hostedClient.List(ctx, pods,
		client.InNamespace(cfg.DPFNamespace),
		client.MatchingLabels{"app.kubernetes.io/component": ovnKubeNodeComponent},
	)).To(Succeed(), "failed to list OVN pods")
	return podUIDsByNode(pods.Items)
}

func waitForOVNServiceRevision(previousServiceUIDs map[types.UID]bool, expectedEnableEgressIP string) {
	By("Waiting for a new Ready OVN DPUService revision")
	Eventually(func(g Gomega) {
		services := listOVNDPUServiceRevisions()
		var newServices []dpuservicev1.DPUService
		for _, service := range services {
			if previousServiceUIDs[service.UID] {
				continue
			}
			value, found, err := ovnEnableEgressIPFromDPUService(&service)
			g.Expect(err).NotTo(HaveOccurred())
			if (found && value == expectedEnableEgressIP) || (!found && expectedEnableEgressIP == "") {
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

func waitForOVNPodsReplaced(previousPodUIDs map[string]map[types.UID]bool) {
	By("Waiting for all OVN pods to be replaced and Ready")
	Eventually(func(g Gomega) {
		pods := &corev1.PodList{}
		g.Expect(hostedClient.List(ctx, pods,
			client.InNamespace(cfg.DPFNamespace),
			client.MatchingLabels{"app.kubernetes.io/component": ovnKubeNodeComponent},
		)).To(Succeed())

		for _, node := range dpuWorkers {
			var replacementReady bool
			for i := range pods.Items {
				pod := &pods.Items[i]
				if pod.Spec.NodeName != node.Name || previousPodUIDs[node.Name][pod.UID] {
					continue
				}
				if podIsReady(pod) {
					replacementReady = true
					break
				}
			}
			g.Expect(replacementReady).To(BeTrue(),
				"DPU worker %s should have a Ready replacement OVN pod", node.Name)
		}
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(10 * time.Second).Should(Succeed())
}
