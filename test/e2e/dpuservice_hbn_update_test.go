package e2e

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/manifests"
	"github.com/openshift-dpf/test/utils"
)

const hbnDPUServiceConfigurationName = "hbn"

// hbnBGPPeerGroupLineRegexp is a regexp matching any bgp_peer_group line,
// capturing its value, anchored to line boundaries.
var hbnBGPPeerGroupLineRegexp = regexp.MustCompile(`(?m)^\s*bgp_peer_group:\s*(\S+)\s*$`)

// extractHBNBGPPeerGroup returns the current bgp_peer_group value found in
// the given perDPUValuesYAML string.
func extractHBNBGPPeerGroup(perDPUYAML string) (string, error) {
	match := hbnBGPPeerGroupLineRegexp.FindStringSubmatch(perDPUYAML)
	if match == nil {
		return "", fmt.Errorf("no bgp_peer_group line found in perDPUValuesYAML: %s", perDPUYAML)
	}
	return match[1], nil
}

// generateHBNBGPPeerGroup builds a bgp_peer_group value derived from the
// original one but with a random suffix, guaranteeing it never collides with
// the original value.
func generateHBNBGPPeerGroup(original string) string {
	return fmt.Sprintf("%s-test-%s", original, rand.String(5))
}

// scaleWorkloadReplicas rewrites the hard-coded "replicas: 2" for the
// per-DPU-host workload Deployments (sriov-test-worker and
// sriov-test-worker-hostnetwork) in the workload manifest to match the given
// DPU-enabled host node count. The sriov-test-master Deployment uses
// "replicas: 1" and is left untouched.
func scaleWorkloadReplicas(manifestBytes []byte, nodeCount int) []byte {
	return []byte(strings.ReplaceAll(string(manifestBytes), "replicas: 2", fmt.Sprintf("replicas: %d", nodeCount)))
}

// TC-SVC-001: Update HBN DPUService
//
// Reconfigures the HBN DPUService via a one-time DPUServiceConfiguration
// change (bgp_peer_group -> a freshly generated value derived from the
// original), waits for the resulting rolling update of the HBN DPUService,
// and verifies connectivity is preserved throughout. The original
// configuration is restored at the end of the test.
var _ = Describe("TC-SVC-001: Update HBN DPUService", Label("dpuservice", "update-hbn-dpuservice"), Ordered, func() {
	var (
		hbnPods              []PodInfo
		workloadPods         *WorkloadPods
		originalPerDPUYAML   string
		originalBGPPeerGroup string
		updatedBGPPeerGroup  string
		preUpdateHBNUIDs     map[types.UID]bool
	)

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available — skipping TC-SVC-001")
		}

		// Safety net: if a later spec in this Ordered container fails or is
		// skipped, the explicit "should restore original bgp_peer_group"
		// spec below never runs, leaving the shared HBN
		// DPUServiceConfiguration permanently altered for other tests
		// sharing the cluster. DeferCleanup registered in BeforeAll runs
		// once, after the whole Ordered container completes regardless of
		// pass/fail/skip (AfterAll semantics) — unlike DeferCleanup inside
		// an It, which would run right after that single spec. It reads
		// originalBGPPeerGroup via closure, populated later once the
		// pre-condition spec runs, and is idempotent: a no-op if that value
		// was never captured or the configuration already matches it (e.g.
		// the in-flow restore spec already succeeded).
		DeferCleanup(func() {
			if originalBGPPeerGroup == "" {
				return
			}
			current, err := extractHBNBGPPeerGroup(getHBNPerDPUValuesYAML())
			if err != nil || current == originalBGPPeerGroup {
				return
			}
			By(fmt.Sprintf("Cleanup: restoring bgp_peer_group %s -> %s", current, originalBGPPeerGroup))
			Expect(patchHBNPerDPUValuesYAML(
				"bgp_peer_group: "+current,
				"bgp_peer_group: "+originalBGPPeerGroup,
			)).To(Succeed())
		})
	})

	// ── Pre-conditions ──────────────────────────────────────────────────────

	It("pre-condition: should have DPUDeployment in Ready state", func() {
		dpuDeployment := getDPUDeployment()
		Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
			"DPUDeployment must be Ready before HBN update test")
	})

	It("pre-condition: should have HBN DPUServiceConfiguration with a bgp_peer_group set", func() {
		perDPUYAML := getHBNPerDPUValuesYAML()

		var err error
		originalBGPPeerGroup, err = extractHBNBGPPeerGroup(perDPUYAML)
		Expect(err).NotTo(HaveOccurred(), "HBN DPUServiceConfiguration should have a bgp_peer_group set")

		// Derive the value used for the update from the original one, with a
		// random suffix so it can never collide with the original value.
		updatedBGPPeerGroup = generateHBNBGPPeerGroup(originalBGPPeerGroup)

		originalPerDPUYAML = perDPUYAML
	})

	It("pre-condition: should have HBN DPUServices Ready", func() {
		hbnServices := listHBNDPUServices()
		Expect(hbnServices).NotTo(BeEmpty(), "no HBN DPUServices found owned by DPUDeployment")

		for _, svc := range hbnServices {
			Expect(isReady(svc.Status.Conditions)).To(BeTrue(),
				"HBN DPUService %s should be Ready before update", svc.Name)
		}
	})

	// ── Workload / connectivity setup ────────────────────────────────────────

	It("should deploy workload pods", func() {
		// The manifests hard-code 2 replicas for the per-DPU-host workloads,
		// but discoverWorkloadPods expects exactly one worker and one
		// hostnetwork pod per discovered DPU-enabled host node. Rewrite the
		// replica count before applying so the Deployments are created (or
		// updated) with the right count directly — scaling them down in a
		// separate step afterward would transiently overshoot to 2 replicas
		// and could race with pod discovery — so scheduling doesn't fail
		// (e.g. two hostNetwork pods competing for the same port) on
		// clusters with fewer than 2 DPU nodes.
		Expect(dpuHostWorkers).NotTo(BeEmpty(), "no DPU-enabled host worker nodes discovered")
		manifestBytes := scaleWorkloadReplicas(manifests.WorkloadManifestBytes(), len(dpuHostWorkers))

		By("Applying workload manifests to management cluster")
		Expect(utils.ApplyManifests(ctx, mgmtClient, manifestBytes)).To(Succeed(),
			"failed to apply workload manifests")

		By("Waiting for all workload deployments to be ready")
		Expect(utils.WaitForDeployments(ctx, mgmtClient, cfg.WorkloadNamespace, 5*time.Minute)).To(Succeed(),
			"workload deployments not ready")
	})

	It("should discover HBN and workload pods", func() {
		Expect(dpuWorkers).NotTo(BeEmpty(), "no DPU worker nodes discovered")
		Expect(dpuHostWorkers).NotTo(BeEmpty(), "no DPU-enabled host worker nodes discovered")

		var err error
		hbnPods, err = discoverHBNPods(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace, dpuWorkers)
		Expect(err).NotTo(HaveOccurred())
		Expect(hbnPods).To(HaveLen(len(dpuWorkers)))

		workloadPods, err = discoverWorkloadPods(ctx, mgmtClient, cfg.WorkloadNamespace, dpuHostWorkers)
		Expect(err).NotTo(HaveOccurred())

		for _, p := range hbnPods {
			GinkgoWriter.Printf("HBN pod %s on node %s, IP=%s\n", p.Name, p.NodeName, p.IP)
		}
	})

	It("should have network connectivity before config change", func() {
		verifyWorkloadToHBNConnectivity(workloadPods, hbnPods)
	})

	// ── Reconfigure HBN ───────────────────────────────────────────────────────

	It("should update bgp_peer_group in HBN DPUServiceConfiguration", func() {
		preUpdateHBNUIDs = hbnServiceUIDs(listHBNDPUServices())
		Expect(preUpdateHBNUIDs).NotTo(BeEmpty(), "no HBN DPUServices found before update")

		By(fmt.Sprintf("Patching DPUServiceConfiguration %s: bgp_peer_group %s -> %s",
			hbnDPUServiceConfigurationName, originalBGPPeerGroup, updatedBGPPeerGroup))
		Expect(patchHBNPerDPUValuesYAML(
			"bgp_peer_group: "+originalBGPPeerGroup,
			"bgp_peer_group: "+updatedBGPPeerGroup,
		)).To(Succeed())
	})

	It("should wait for HBN DPUService rolling update to complete", func() {
		waitForHBNDPUServicesRolled(preUpdateHBNUIDs)
	})

	It("should verify bgp_peer_group change in DPUServiceConfiguration", func() {
		perDPUYAML := getHBNPerDPUValuesYAML()
		currentBGPPeerGroup, err := extractHBNBGPPeerGroup(perDPUYAML)
		Expect(err).NotTo(HaveOccurred())
		// Compare the exact extracted value rather than a substring, since
		// the generated updated value is itself prefixed with the original
		// value (e.g. "hbn-test-abcde" contains "hbn"), so a plain
		// substring check against the original would still match.
		Expect(currentBGPPeerGroup).To(Equal(updatedBGPPeerGroup),
			"HBN DPUServiceConfiguration should reflect updated bgp_peer_group")
	})

	It("should rediscover HBN pods after rolling update", func() {
		Eventually(func(g Gomega) {
			pods, err := discoverHBNPods(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace, dpuWorkers)
			g.Expect(err).NotTo(HaveOccurred())
			g.Expect(pods).To(HaveLen(len(dpuWorkers)))
			hbnPods = pods
		}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

		for _, p := range hbnPods {
			GinkgoWriter.Printf("HBN pod %s on node %s, IP=%s\n", p.Name, p.NodeName, p.IP)
		}
	})

	It("should have network connectivity after config change", func() {
		workloadPods = rediscoverWorkloadPods()
		verifyWorkloadToHBNConnectivity(workloadPods, hbnPods)
	})

	// ── Restore original configuration ──────────────────────────────────────

	It("should restore original bgp_peer_group in HBN DPUServiceConfiguration", func() {
		preRestoreHBNUIDs := hbnServiceUIDs(listHBNDPUServices())
		Expect(preRestoreHBNUIDs).NotTo(BeEmpty(), "no HBN DPUServices found before restore")

		By(fmt.Sprintf("Patching DPUServiceConfiguration %s: bgp_peer_group %s -> %s",
			hbnDPUServiceConfigurationName, updatedBGPPeerGroup, originalBGPPeerGroup))
		Expect(patchHBNPerDPUValuesYAML(
			"bgp_peer_group: "+updatedBGPPeerGroup,
			"bgp_peer_group: "+originalBGPPeerGroup,
		)).To(Succeed())

		waitForHBNDPUServicesRolled(preRestoreHBNUIDs)

		perDPUYAML := getHBNPerDPUValuesYAML()
		Expect(perDPUYAML).To(Equal(originalPerDPUYAML),
			"HBN DPUServiceConfiguration perDPUValuesYAML should match its original value after restore")
	})

	It("should rediscover HBN pods after restore rolling update", func() {
		Eventually(func(g Gomega) {
			pods, err := discoverHBNPods(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace, dpuWorkers)
			g.Expect(err).NotTo(HaveOccurred())
			g.Expect(pods).To(HaveLen(len(dpuWorkers)))
			hbnPods = pods
		}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())
	})

	It("should have network connectivity after restore", func() {
		workloadPods = rediscoverWorkloadPods()
		verifyWorkloadToHBNConnectivity(workloadPods, hbnPods)
	})

	It("should have a healthy cluster after HBN reconfiguration", func() {
		waitForClusterHealth()
	})
})

// listHBNDPUServices lists the DPUServices owned by the configured
// DPUDeployment whose name identifies them as HBN services, consistent with
// discoverHBNPods in helpers.go.
func listHBNDPUServices() []dpuservicev1.DPUService {
	ownedBy := client.MatchingLabels{
		dpuservicev1.ParentDPUDeploymentNameLabel: cfg.DPFNamespace + "_" + cfg.DPUDeploymentName,
	}
	svcList := &dpuservicev1.DPUServiceList{}
	Expect(mgmtClient.List(ctx, svcList,
		client.InNamespace(cfg.DPFNamespace), ownedBy)).To(Succeed())

	var hbn []dpuservicev1.DPUService
	for _, svc := range svcList.Items {
		if strings.Contains(svc.Name, "hbn") {
			hbn = append(hbn, svc)
		}
	}
	return hbn
}

func hbnServiceUIDs(services []dpuservicev1.DPUService) map[types.UID]bool {
	uids := make(map[types.UID]bool, len(services))
	for _, svc := range services {
		uids[svc.UID] = true
	}
	return uids
}

// waitForHBNDPUServicesRolled waits until every HBN DPUService owned by the
// DPUDeployment is new relative to preUIDs (i.e. rolled) and Ready.
func waitForHBNDPUServicesRolled(preUIDs map[types.UID]bool) {
	By("Waiting for HBN DPUService rolling update to complete")
	Eventually(func(g Gomega) {
		hbnServices := listHBNDPUServices()
		g.Expect(hbnServices).NotTo(BeEmpty(), "expected at least one HBN DPUService")

		for _, svc := range hbnServices {
			g.Expect(preUIDs[svc.UID]).To(BeFalse(),
				"HBN DPUService %s should have been replaced by the rolling update", svc.Name)
			g.Expect(isReady(svc.Status.Conditions)).To(BeTrue(),
				"HBN DPUService %s should be Ready after rolling update", svc.Name)
		}
	}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(10 * time.Second).Should(Succeed())

	GinkgoWriter.Printf("HBN DPUService rolling update complete\n")
}

// getHBNDPUServiceConfiguration fetches the "hbn" DPUServiceConfiguration.
func getHBNDPUServiceConfiguration() *dpuservicev1.DPUServiceConfiguration {
	dsc := &dpuservicev1.DPUServiceConfiguration{}
	Expect(mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.DPFNamespace,
		Name:      hbnDPUServiceConfigurationName,
	}, dsc)).To(Succeed(), "failed to get HBN DPUServiceConfiguration")
	return dsc
}

// getHBNPerDPUValuesYAML returns the current perDPUValuesYAML string nested
// inside the HBN DPUServiceConfiguration's helm chart values.
func getHBNPerDPUValuesYAML() string {
	dsc := getHBNDPUServiceConfiguration()
	valuesMap, err := decodeHelmValues(dsc)
	Expect(err).NotTo(HaveOccurred())

	yamlStr, err := perDPUValuesYAML(valuesMap)
	Expect(err).NotTo(HaveOccurred())
	return yamlStr
}

// patchHBNPerDPUValuesYAML replaces the first occurrence of oldSubstr with
// newSubstr inside the HBN DPUServiceConfiguration's perDPUValuesYAML and
// applies the change via Update.
func patchHBNPerDPUValuesYAML(oldSubstr, newSubstr string) error {
	dsc := getHBNDPUServiceConfiguration()

	valuesMap, err := decodeHelmValues(dsc)
	if err != nil {
		return err
	}

	yamlStr, err := perDPUValuesYAML(valuesMap)
	if err != nil {
		return err
	}
	if !strings.Contains(yamlStr, oldSubstr) {
		return fmt.Errorf("perDPUValuesYAML does not contain %q: %s", oldSubstr, yamlStr)
	}

	configMap, ok := valuesMap["configuration"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("helm values missing configuration map")
	}
	configMap["perDPUValuesYAML"] = strings.Replace(yamlStr, oldSubstr, newSubstr, 1)

	newRaw, err := json.Marshal(valuesMap)
	if err != nil {
		return fmt.Errorf("marshalling updated helm values: %w", err)
	}
	dsc.Spec.ServiceConfiguration.HelmChart.Values = &runtime.RawExtension{Raw: newRaw}

	return mgmtClient.Update(ctx, dsc)
}

func decodeHelmValues(dsc *dpuservicev1.DPUServiceConfiguration) (map[string]interface{}, error) {
	if dsc.Spec.ServiceConfiguration.HelmChart.Values == nil {
		return nil, fmt.Errorf("DPUServiceConfiguration %s has no helm chart values", dsc.Name)
	}
	var valuesMap map[string]interface{}
	if err := json.Unmarshal(dsc.Spec.ServiceConfiguration.HelmChart.Values.Raw, &valuesMap); err != nil {
		return nil, fmt.Errorf("unmarshalling helm values: %w", err)
	}
	return valuesMap, nil
}

func perDPUValuesYAML(valuesMap map[string]interface{}) (string, error) {
	configMap, ok := valuesMap["configuration"].(map[string]interface{})
	if !ok {
		return "", fmt.Errorf("helm values missing configuration map")
	}
	yamlStr, ok := configMap["perDPUValuesYAML"].(string)
	if !ok {
		return "", fmt.Errorf("configuration missing perDPUValuesYAML string")
	}
	return yamlStr, nil
}

// rediscoverWorkloadPods retries discovering the workload pods for a while.
// The DPU-enabled host node runs both the HBN pod and the workload pods, and
// an HBN DPUService rolling update triggers a node maintenance drain/
// uncordon cycle on that same node (node effect on DPUService label change),
// which transiently evicts and reschedules the workload pods too.
func rediscoverWorkloadPods() *WorkloadPods {
	var pods *WorkloadPods
	Eventually(func(g Gomega) {
		var err error
		pods, err = discoverWorkloadPods(ctx, mgmtClient, cfg.WorkloadNamespace, dpuHostWorkers)
		g.Expect(err).NotTo(HaveOccurred())
	}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())
	return pods
}

// pingEventually retries a ping from a workload pod to an HBN pod, tolerating
// transient packet loss immediately after an HBN rolling update while BGP
// sessions and routes reconverge.
func pingEventually(podName, destIP string) {
	Eventually(func() error {
		return utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
			cfg.WorkloadNamespace, podName, "nginx", destIP, cfg.PingCount, 0)
	}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())
}

// verifyWorkloadToHBNConnectivity pings from the master pod and each same-node
// worker/hostnetwork pod to its corresponding HBN pod.
func verifyWorkloadToHBNConnectivity(workloadPods *WorkloadPods, hbnPods []PodInfo) {
	Expect(workloadPods).NotTo(BeNil(), "workload pods not discovered")
	Expect(hbnPods).NotTo(BeEmpty(), "HBN pods not discovered")

	for _, hbn := range hbnPods {
		By(fmt.Sprintf("Pinging from %s to HBN %s (IP=%s)", workloadPods.Master.Name, hbn.Name, hbn.IP))
		pingEventually(workloadPods.Master.Name, hbn.IP)
	}

	for i, worker := range workloadPods.Workers {
		if i >= len(hbnPods) {
			break
		}
		By(fmt.Sprintf("Pinging from %s to HBN %s (IP=%s)", worker.Name, hbnPods[i].Name, hbnPods[i].IP))
		pingEventually(worker.Name, hbnPods[i].IP)
	}

	for i, hnw := range workloadPods.HostNetWorkers {
		if i >= len(hbnPods) {
			break
		}
		By(fmt.Sprintf("Pinging from %s to HBN %s (IP=%s)", hnw.Name, hbnPods[i].Name, hbnPods[i].IP))
		pingEventually(hnw.Name, hbnPods[i].IP)
	}
}
