package e2e

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"regexp"
	"strconv"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/manifests"
	"github.com/openshift-dpf/test/utils"
)

// dpuServiceChainVersionAnnotation is set by the DPUDeployment controller on
// every DPUServiceChain it creates; its value changes whenever the rendered
// chain spec changes, which lets us detect a reconciled path swap.
const dpuServiceChainVersionAnnotation = "svc.dpu.nvidia.com/dpuservicechain-version"

// serviceChainSetNameLabel is set by the servicechainset-controller on every
// per-node ServiceChain object it creates on the hosted (DPU) cluster; its
// value is the name of the owning DPUServiceChain (which acts as a
// ServiceChainSet). Used to find the hosted-cluster ServiceChain rendered
// from a given management-cluster DPUServiceChain.
const serviceChainSetNameLabel = "svc.dpu.nvidia.com/servicechainset-name"

// svcInterfaceMatchLabelKey is the matchLabels key the DPUDeployment
// controller uses to identify the DPUService-side port of a rendered
// DPUServiceChain switch (as opposed to the physical-uplink side).
const svcInterfaceMatchLabelKey = "svc.dpu.nvidia.com/interface"

// sfcControllerContainer is the container name of the sfc-controller pods
// that own the br-sfc OVS bridge and program its flow rules.
const sfcControllerContainer = "sfc-controller"

// uplinkSwitch describes one DPUDeployment serviceChains switch that pairs a
// physical uplink (identified by its "uplink" matchLabels value, e.g. "p0")
// with an HBN service interface (e.g. "p0_if").
type uplinkSwitch struct {
	index         int
	uplinkLabel   string
	interfaceName string
}

// findUplinkSwitches returns the switches whose ports pair a physical
// uplink (serviceInterface.matchLabels["uplink"]) with an HBN service port.
func findUplinkSwitches(switches []dpuservicev1.DPUDeploymentSwitch) []uplinkSwitch {
	var found []uplinkSwitch
	for i, sw := range switches {
		var uplinkLabel, ifaceName string
		for _, port := range sw.Ports {
			if port.ServiceInterface != nil {
				if v, ok := port.ServiceInterface.MatchLabels["uplink"]; ok {
					uplinkLabel = v
				}
			}
			if port.Service != nil {
				ifaceName = port.Service.InterfaceName
			}
		}
		if uplinkLabel != "" && ifaceName != "" {
			found = append(found, uplinkSwitch{index: i, uplinkLabel: uplinkLabel, interfaceName: ifaceName})
		}
	}
	return found
}

// setSwitchServiceInterfaceName rewrites the InterfaceName of the DPUService
// port (as opposed to the physical uplink port) of the given switch.
func setSwitchServiceInterfaceName(sw *dpuservicev1.DPUDeploymentSwitch, name string) {
	for i := range sw.Ports {
		if sw.Ports[i].Service != nil {
			sw.Ports[i].Service.InterfaceName = name
		}
	}
}

// renderedSwitchInterfaceName extracts the uplink matchLabels value and the
// paired HBN interface name from a rendered DPUServiceChain switch.
func renderedSwitchInterfaceName(sw dpuservicev1.Switch) (uplink, iface string) {
	for _, port := range sw.Ports {
		if v, ok := port.ServiceInterface.MatchLabels["uplink"]; ok {
			uplink = v
		}
		if v, ok := port.ServiceInterface.MatchLabels[svcInterfaceMatchLabelKey]; ok {
			iface = v
		}
	}
	return uplink, iface
}

// ovsPairing represents one table=1, priority=0 catch-all forwarding rule
// captured from `ovs-ofctl dump-flows br-sfc`, i.e. "packets arriving on
// InPort with an unknown destination MAC are flooded to OutPort".
type ovsPairing struct {
	InPort  int
	OutPort int
}

var (
	ovsCatchAllRegexp    = regexp.MustCompile(`cookie=0x([0-9a-fA-F]+).*priority=0,in_port=(\d+) actions=output:(\d+)`)
	bgpEstablishedRegexp = regexp.MustCompile(`BGP state = Established`)
)

// parseOVSInterfaces parses the JSON output of
// `ovs-vsctl --format=json --columns=name,ofport list Interface` into a
// map of interface name to OpenFlow port number.
func parseOVSInterfaces(jsonOutput string) (map[string]int, error) {
	var parsed struct {
		Data [][]interface{} `json:"data"`
	}
	if err := json.Unmarshal([]byte(jsonOutput), &parsed); err != nil {
		return nil, fmt.Errorf("parsing ovs-vsctl JSON output: %w", err)
	}

	result := make(map[string]int, len(parsed.Data))
	for _, row := range parsed.Data {
		if len(row) != 2 {
			continue
		}
		name, ok := row[0].(string)
		if !ok {
			continue
		}
		ofport, ok := row[1].(float64)
		if !ok {
			continue
		}
		result[name] = int(ofport)
	}
	return result, nil
}

// parseOVSFlowPairings parses the output of `ovs-ofctl dump-flows br-sfc`
// and extracts the table=1, priority=0 catch-all forwarding rules -- the
// rules with only an in_port match and no dl_dst, which define which port
// each service-chain switch pairs with. It also returns the single cookie
// value shared by all those rules, zero-padded to 16 hex digits.
func parseOVSFlowPairings(flowOutput string) (pairings []ovsPairing, cookie string, err error) {
	seenCookies := make(map[string]bool)
	for _, line := range strings.Split(flowOutput, "\n") {
		m := ovsCatchAllRegexp.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		inPort, errIn := strconv.Atoi(m[2])
		outPort, errOut := strconv.Atoi(m[3])
		if errIn != nil || errOut != nil {
			continue
		}
		seenCookies[padHex16(m[1])] = true
		pairings = append(pairings, ovsPairing{InPort: inPort, OutPort: outPort})
	}

	if len(pairings) == 0 {
		return nil, "", fmt.Errorf("no priority=0 catch-all pairing rules found in flow output:\n%s", flowOutput)
	}
	if len(seenCookies) != 1 {
		return nil, "", fmt.Errorf("expected a single cookie across catch-all flows, found %d: %v", len(seenCookies), seenCookies)
	}
	for c := range seenCookies {
		cookie = c
	}
	return pairings, cookie, nil
}

// pairedPort returns the ofPort that inPort is forwarded to by the
// catch-all rules, i.e. the port it is "paired" with in the service chain.
func pairedPort(pairings []ovsPairing, inPort int) (int, bool) {
	for _, p := range pairings {
		if p.InPort == inPort {
			return p.OutPort, true
		}
	}
	return 0, false
}

// pairingSet converts a pairing slice to a set for order-independent
// comparison.
func pairingSet(pairings []ovsPairing) map[ovsPairing]bool {
	set := make(map[ovsPairing]bool, len(pairings))
	for _, p := range pairings {
		set[p] = true
	}
	return set
}

// computeSFCCookie computes the FNV-1a-64 hash of "namespace/name",
// zero-padded to 16 hex digits. The sfc-controller uses this exact scheme
// (hashing the *hosted-cluster* ServiceChain object's own namespace/name,
// e.g. "dpf-operator-system/dpudeployment-d5pzlvs9lj") to derive the OVS
// flow cookie that identifies which ServiceChain owns a given set of flows.
// Note this is NOT the management-cluster DPUServiceChain's namespace/name:
// the servicechainset-controller renders one ServiceChain per DPU node from
// each DPUServiceChain (acting as a ServiceChainSet), appending a per-node
// suffix to the name, and it is that rendered object's identity which is
// hashed.
func computeSFCCookie(namespace, name string) string {
	h := fnv.New64a()
	_, _ = h.Write([]byte(namespace + "/" + name))
	return fmt.Sprintf("%016x", h.Sum64())
}

// findHostedServiceChain looks up the hosted-cluster ServiceChain rendered
// from the DPUServiceChain (ServiceChainSet) named chainSetName, identified
// via the servicechainset-name label the servicechainset-controller stamps
// on every ServiceChain it creates. Assumes a single-DPU-node environment
// (as validated by the test's pre-conditions), so exactly one match is
// expected.
func findHostedServiceChain(chainSetName string) dpuservicev1.ServiceChain {
	list := &dpuservicev1.ServiceChainList{}
	Expect(hostedClient.List(ctx, list,
		client.InNamespace(cfg.DPFNamespace),
		client.MatchingLabels{serviceChainSetNameLabel: chainSetName},
	)).To(Succeed(), "failed to list hosted ServiceChains for ServiceChainSet %s", chainSetName)
	Expect(list.Items).To(HaveLen(1),
		"expected exactly one hosted ServiceChain for ServiceChainSet %s, found %d", chainSetName, len(list.Items))
	return list.Items[0]
}

// expectedSFCCookieFor returns the OVS flow cookie the sfc-controller is
// expected to program for the DPUServiceChain (ServiceChainSet) named
// chainSetName, computed from its rendered hosted-cluster ServiceChain's
// own namespace/name.
func expectedSFCCookieFor(chainSetName string) string {
	sc := findHostedServiceChain(chainSetName)
	return computeSFCCookie(sc.Namespace, sc.Name)
}

// padHex16 lower-cases and zero-pads a hex string to 16 digits so cookies
// captured from `ovs-ofctl` output (which may omit leading zeros) can be
// compared against computeSFCCookie's fixed-width output.
func padHex16(s string) string {
	s = strings.ToLower(s)
	if len(s) < 16 {
		s = strings.Repeat("0", 16-len(s)) + s
	}
	return s
}

// discoverSFCControllerPods lists the running sfc-controller pods on the
// hosted (DPU) cluster; these own the br-sfc OVS bridge.
func discoverSFCControllerPods() []corev1.Pod {
	pods, err := utils.GetRunningPods(ctx, hostedClient, cfg.DPFNamespace, map[string]string{"app.kubernetes.io/name": "sfc-controller"})
	Expect(err).NotTo(HaveOccurred(), "failed to list sfc-controller pods")
	Expect(pods).NotTo(BeEmpty(), "no sfc-controller pods found in hosted cluster")
	return pods
}

// captureOVSState execs into the given sfc-controller pod to capture the
// current interface->ofPort mapping and br-sfc flow-rule pairings/cookie.
func captureOVSState(pod corev1.Pod) (interfaces map[string]int, pairings []ovsPairing, cookie string) {
	ifaceResult, err := utils.ExecInPod(ctx, hostedConfig, hostedClientset, pod.Namespace, pod.Name, sfcControllerContainer,
		[]string{"ovs-vsctl", "--format=json", "--columns=name,ofport", "list", "Interface"})
	Expect(err).NotTo(HaveOccurred(), "failed to list OVS interfaces on pod %s", pod.Name)
	interfaces, err = parseOVSInterfaces(ifaceResult.Stdout)
	Expect(err).NotTo(HaveOccurred(), "failed to parse OVS interfaces on pod %s", pod.Name)

	flowResult, err := utils.ExecInPod(ctx, hostedConfig, hostedClientset, pod.Namespace, pod.Name, sfcControllerContainer,
		[]string{"ovs-ofctl", "dump-flows", "br-sfc"})
	Expect(err).NotTo(HaveOccurred(), "failed to dump OVS flows on pod %s", pod.Name)
	pairings, cookie, err = parseOVSFlowPairings(flowResult.Stdout)
	Expect(err).NotTo(HaveOccurred(), "failed to parse OVS flow pairings on pod %s", pod.Name)

	return interfaces, pairings, cookie
}

// verifyBGPEstablished execs `vtysh -c "show bgp neighbors <iface>"` in the
// given HBN pod for each interface and asserts the session is Established.
func verifyBGPEstablished(pod PodInfo, interfaceNames []string) error {
	for _, iface := range interfaceNames {
		result, err := utils.ExecInPod(ctx, hostedConfig, hostedClientset, pod.Namespace, pod.Name, "doca-hbn",
			[]string{"vtysh", "-c", fmt.Sprintf("show bgp neighbors %s", iface)})
		if err != nil {
			return fmt.Errorf("exec vtysh on %s for interface %s: %w", pod.Name, iface, err)
		}
		if !bgpEstablishedRegexp.MatchString(result.Stdout) {
			return fmt.Errorf("BGP neighbor %s on pod %s is not Established:\n%s", iface, pod.Name, result.Stdout)
		}
	}
	return nil
}

// listOwnedDPUServiceChains lists the DPUServiceChains owned by the
// configured DPUDeployment.
func listOwnedDPUServiceChains() []dpuservicev1.DPUServiceChain {
	ownedBy := client.MatchingLabels{
		dpuservicev1.ParentDPUDeploymentNameLabel: cfg.DPFNamespace + "_" + cfg.DPUDeploymentName,
	}
	chainList := &dpuservicev1.DPUServiceChainList{}
	Expect(mgmtClient.List(ctx, chainList,
		client.InNamespace(cfg.DPFNamespace), ownedBy)).To(Succeed())
	return chainList.Items
}

// serviceChainUIDs returns the set of UIDs of the given DPUServiceChains.
func serviceChainUIDs(chains []dpuservicev1.DPUServiceChain) map[types.UID]bool {
	uids := make(map[types.UID]bool, len(chains))
	for _, c := range chains {
		uids[c.UID] = true
	}
	return uids
}

// getDPUServiceChainByName fetches a single DPUServiceChain by name.
func getDPUServiceChainByName(name string) *dpuservicev1.DPUServiceChain {
	chain := &dpuservicev1.DPUServiceChain{}
	Expect(mgmtClient.Get(ctx, client.ObjectKey{
		Namespace: cfg.DPFNamespace,
		Name:      name,
	}, chain)).To(Succeed(), "failed to get DPUServiceChain %s", name)
	return chain
}

// TC-SVC-003: Service Chain Path Update
//
// Swaps the HBN service interface names (e.g. p0_if <-> p1_if) between the
// two physical-uplink switches of the DPUDeployment serviceChains, then
// verifies: the DPUServiceChain reconciles with a new version and rendered
// path, the sfc-controller's OVS flow rules update to reflect the swapped
// pairing (old flows/cookie gone, new cookie owns the new flows), BGP
// re-establishes on the HBN interfaces, and traffic keeps flowing
// throughout. The original wiring is restored at the end.
var _ = Describe("TC-SVC-003: Service Chain Path Update", Label("dpuservice", "service-chain-path-update"), Ordered, func() {
	var (
		originalSwitches []dpuservicev1.DPUDeploymentSwitch
		uplinkSwitches   []uplinkSwitch

		chainName           string
		preSwapChainUIDs    map[types.UID]bool
		preSwapChainVersion string

		sfcControllerPods []corev1.Pod
		preSwapInterfaces map[string]int
		preSwapPairings   []ovsPairing
		preSwapPairedPort map[string]int // uplinkLabel -> ofPort it was paired with
		preSwapCookie     string

		postSwapChainName string

		workloadPods *WorkloadPods
	)

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available — skipping TC-SVC-003")
		}

		// Safety net: restore the original serviceChains switches if a
		// later spec fails or is skipped before the explicit restore step
		// runs, so the shared DPUDeployment isn't left with a swapped path
		// for other tests sharing the cluster.
		DeferCleanup(func() {
			if originalSwitches == nil {
				return
			}
			dpuDeployment := getDPUDeployment()
			if dpuDeployment.Spec.ServiceChains == nil {
				return
			}
			current := dpuDeployment.Spec.ServiceChains.Switches
			if switchesMatch(current, originalSwitches) {
				return
			}
			By("Cleanup: restoring original DPUDeployment serviceChains switches")
			dpuDeployment.Spec.ServiceChains.Switches = originalSwitches
			Expect(mgmtClient.Update(ctx, dpuDeployment)).To(Succeed())
		})
	})

	// ── Pre-conditions ──────────────────────────────────────────────────────

	It("pre-condition: should have DPUDeployment in Ready state", func() {
		dpuDeployment := getDPUDeployment()
		Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
			"DPUDeployment must be Ready before service chain path update test")
	})

	It("pre-condition: should discover the current chain wiring and physical uplinks", func() {
		dpuDeployment := getDPUDeployment()
		Expect(dpuDeployment.Spec.ServiceChains).NotTo(BeNil(), "DPUDeployment has no serviceChains configured")
		Expect(dpuDeployment.Spec.ServiceChains.Switches).NotTo(BeEmpty(), "DPUDeployment serviceChains has no switches")

		originalSwitches = dpuDeployment.Spec.ServiceChains.DeepCopy().Switches

		uplinkSwitches = findUplinkSwitches(originalSwitches)
		Expect(uplinkSwitches).To(HaveLen(2),
			"expected exactly 2 physical-uplink switches to swap, found %d", len(uplinkSwitches))

		for _, us := range uplinkSwitches {
			GinkgoWriter.Printf("Discovered uplink switch: uplink=%s interface=%s (index %d)\n",
				us.uplinkLabel, us.interfaceName, us.index)
		}
	})

	It("pre-condition: should have DPUServiceChain Ready with a version annotation", func() {
		// This test assumes a single-DPU-cluster environment (as validated
		// by pre-condition above via dpfInput.NumberOfDPUNodes), so exactly
		// one DPUServiceChain is expected to be owned by the DPUDeployment.
		chains := listOwnedDPUServiceChains()
		Expect(chains).NotTo(BeEmpty(), "no DPUServiceChain found owned by DPUDeployment")

		chain := chains[0]
		Expect(isReady(chain.Status.Conditions)).To(BeTrue(),
			"DPUServiceChain %s must be Ready before path update test", chain.Name)

		version, ok := chain.Annotations[dpuServiceChainVersionAnnotation]
		Expect(ok).To(BeTrue(), "DPUServiceChain %s missing version annotation %s",
			chain.Name, dpuServiceChainVersionAnnotation)

		chainName = chain.Name
		preSwapChainVersion = version
		preSwapChainUIDs = serviceChainUIDs(chains)

		GinkgoWriter.Printf("DPUServiceChain %s version=%s\n", chainName, preSwapChainVersion)
	})

	// ── Baseline OVS flow capture ─────────────────────────────────────────

	It("should capture baseline OVS flow pairings", func() {
		sfcControllerPods = discoverSFCControllerPods()

		pod := sfcControllerPods[0]
		By(fmt.Sprintf("Capturing OVS interface map and flow rules on %s", pod.Name))
		var cookie string
		preSwapInterfaces, preSwapPairings, cookie = captureOVSState(pod)
		preSwapCookie = cookie

		By("Identifying which port each physical uplink is currently paired with")
		preSwapPairedPort = make(map[string]int, len(uplinkSwitches))
		for _, us := range uplinkSwitches {
			ofPort, ok := preSwapInterfaces[us.uplinkLabel]
			Expect(ok).To(BeTrue(), "no OVS interface found for uplink %q", us.uplinkLabel)
			paired, ok := pairedPort(preSwapPairings, ofPort)
			Expect(ok).To(BeTrue(), "no catch-all pairing found for uplink %q (ofPort %d)", us.uplinkLabel, ofPort)
			preSwapPairedPort[us.uplinkLabel] = paired
			GinkgoWriter.Printf("Baseline: uplink %s (ofPort %d) paired with ofPort %d\n", us.uplinkLabel, ofPort, paired)
		}

		By("Verifying the flow cookie matches FNV-1a-64(namespace/name) of the hosted ServiceChain")
		expectedCookie := expectedSFCCookieFor(chainName)
		Expect(preSwapCookie).To(Equal(expectedCookie),
			"OVS flow cookie should match FNV-1a-64 hash of the hosted ServiceChain rendered from %s/%s", cfg.DPFNamespace, chainName)
	})

	// ── Swap ──────────────────────────────────────────────────────────────

	It("should swap service interface names in DPUDeployment", func() {
		dpuDeployment := getDPUDeployment()
		switches := dpuDeployment.Spec.ServiceChains.Switches

		idxA, idxB := uplinkSwitches[0].index, uplinkSwitches[1].index
		ifaceA, ifaceB := uplinkSwitches[0].interfaceName, uplinkSwitches[1].interfaceName

		By(fmt.Sprintf("Patching DPUDeployment %s: switch[%d] (uplink %s) interface %s <-> switch[%d] (uplink %s) interface %s",
			dpuDeployment.Name, idxA, uplinkSwitches[0].uplinkLabel, ifaceA, idxB, uplinkSwitches[1].uplinkLabel, ifaceB))

		setSwitchServiceInterfaceName(&switches[idxA], ifaceB)
		setSwitchServiceInterfaceName(&switches[idxB], ifaceA)

		Expect(mgmtClient.Update(ctx, dpuDeployment)).To(Succeed())
		GinkgoWriter.Printf("DPUDeployment %s serviceChains patched\n", dpuDeployment.Name)
	})

	// ── Post-swap verification ──────────────────────────────────────────────

	It("should wait for DPUServiceChain to reconcile with the swapped path", func() {
		By("Waiting for a new, Ready DPUServiceChain revision")
		Eventually(func(g Gomega) {
			chains := listOwnedDPUServiceChains()
			g.Expect(chains).NotTo(BeEmpty(), "expected at least one DPUServiceChain")
			for _, c := range chains {
				g.Expect(preSwapChainUIDs[c.UID]).To(BeFalse(),
					"DPUServiceChain %s should have been replaced by the swap", c.Name)
				g.Expect(isReady(c.Status.Conditions)).To(BeTrue(),
					"DPUServiceChain %s should be Ready after swap", c.Name)
			}
			postSwapChainName = chains[0].Name
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(10 * time.Second).Should(Succeed())

		chain := getDPUServiceChainByName(postSwapChainName)

		By("Verifying the DPUServiceChain version annotation changed")
		newVersion := chain.Annotations[dpuServiceChainVersionAnnotation]
		Expect(newVersion).NotTo(Equal(preSwapChainVersion),
			"DPUServiceChain version annotation should change after the path swap")

		By("Verifying the rendered chain carries the swapped service interface labels")
		rendered := chain.Spec.Template.Spec.Template.Spec.Switches
		expectedInterfaceFor := map[string]string{
			uplinkSwitches[0].uplinkLabel: uplinkSwitches[1].interfaceName,
			uplinkSwitches[1].uplinkLabel: uplinkSwitches[0].interfaceName,
		}
		for uplinkLabel, expectedIface := range expectedInterfaceFor {
			var found bool
			for _, sw := range rendered {
				uplink, iface := renderedSwitchInterfaceName(sw)
				if uplink != uplinkLabel {
					continue
				}
				found = true
				Expect(iface).To(Equal(expectedIface),
					"rendered switch for uplink %s should carry interface %s after swap", uplinkLabel, expectedIface)
			}
			Expect(found).To(BeTrue(), "no rendered switch found for uplink %s", uplinkLabel)
		}

		GinkgoWriter.Printf("DPUServiceChain reconciled: %s -> %s (version %s -> %s)\n",
			chainName, postSwapChainName, preSwapChainVersion, newVersion)
	})

	It("should verify OVS flow pairings are swapped and old flows removed", func() {
		pod := sfcControllerPods[0]
		By(fmt.Sprintf("Re-capturing OVS interface map and flow rules on %s", pod.Name))
		postSwapInterfaces, postSwapPairings, postSwapCookie := captureOVSState(pod)

		By("Verifying the two physical uplinks now pair with each other's original partner")
		postSwapPairedPort := make(map[string]int, len(uplinkSwitches))
		for _, us := range uplinkSwitches {
			ofPort, ok := postSwapInterfaces[us.uplinkLabel]
			Expect(ok).To(BeTrue(), "no OVS interface found for uplink %q after swap", us.uplinkLabel)
			paired, ok := pairedPort(postSwapPairings, ofPort)
			Expect(ok).To(BeTrue(), "no catch-all pairing found for uplink %q after swap", us.uplinkLabel)
			postSwapPairedPort[us.uplinkLabel] = paired
			GinkgoWriter.Printf("After swap: uplink %s (ofPort %d) paired with ofPort %d\n", us.uplinkLabel, ofPort, paired)
		}

		labelA, labelB := uplinkSwitches[0].uplinkLabel, uplinkSwitches[1].uplinkLabel
		Expect(postSwapPairedPort[labelA]).To(Equal(preSwapPairedPort[labelB]),
			"uplink %s should now be paired with the port %s was previously paired with", labelA, labelB)
		Expect(postSwapPairedPort[labelB]).To(Equal(preSwapPairedPort[labelA]),
			"uplink %s should now be paired with the port %s was previously paired with", labelB, labelA)

		By("Verifying all other flow pairings (e.g. OVN uplink) are unchanged")
		changedInPorts := map[int]bool{
			preSwapInterfaces[labelA]: true,
			preSwapInterfaces[labelB]: true,
			preSwapPairedPort[labelA]: true,
			preSwapPairedPort[labelB]: true,
		}
		postSet := pairingSet(postSwapPairings)
		for _, p := range preSwapPairings {
			if changedInPorts[p.InPort] {
				continue
			}
			Expect(postSet[p]).To(BeTrue(),
				"pairing %+v present before swap is missing after swap (unintended flow change)", p)
		}

		By("Verifying the flow cookie changed and matches the new DPUServiceChain")
		expectedNewCookie := expectedSFCCookieFor(postSwapChainName)
		Expect(postSwapCookie).To(Equal(expectedNewCookie),
			"OVS flow cookie should match FNV-1a-64 hash of the hosted ServiceChain rendered from new %s/%s", cfg.DPFNamespace, postSwapChainName)
		Expect(postSwapCookie).NotTo(Equal(preSwapCookie),
			"OVS flow cookie should change after the chain swap — old flows should be removed")
	})

	It("should verify BGP sessions re-establish", func() {
		hbnPods, err := discoverHBNPods(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace, dpuWorkers)
		Expect(err).NotTo(HaveOccurred())
		Expect(hbnPods).NotTo(BeEmpty(), "no HBN pods discovered")

		interfaceNames := []string{uplinkSwitches[0].interfaceName, uplinkSwitches[1].interfaceName}

		Eventually(func(g Gomega) {
			for _, pod := range hbnPods {
				g.Expect(verifyBGPEstablished(pod, interfaceNames)).To(Succeed())
			}
		}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

		GinkgoWriter.Printf("BGP sessions Established on %v across %d HBN pod(s)\n", interfaceNames, len(hbnPods))
	})

	// ── Traffic verification ────────────────────────────────────────────────

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

	It("should verify traffic connectivity after swap", func() {
		hbnPods, err := discoverHBNPods(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace, dpuWorkers)
		Expect(err).NotTo(HaveOccurred())
		Expect(hbnPods).To(HaveLen(len(dpuWorkers)))

		workloadPods, err = discoverWorkloadPods(ctx, mgmtClient, cfg.WorkloadNamespace, dpuHostWorkers)
		Expect(err).NotTo(HaveOccurred())

		verifyWorkloadToHBNConnectivity(workloadPods, hbnPods)

		if cfg.ExternalRouterIP != "" {
			By(fmt.Sprintf("Pinging external router %s from workload master pod (full swapped path)", cfg.ExternalRouterIP))
			pingEventually(workloadPods.Master.Name, cfg.ExternalRouterIP)
		} else {
			GinkgoWriter.Printf("EXTERNAL_ROUTER_IP not configured — skipping external router ping\n")
		}
	})

	// ── Restore original configuration ──────────────────────────────────────

	It("should restore original serviceChains", func() {
		preRestoreChainUIDs := serviceChainUIDs(listOwnedDPUServiceChains())
		Expect(preRestoreChainUIDs).NotTo(BeEmpty(), "no DPUServiceChain found before restore")

		dpuDeployment := getDPUDeployment()
		By("Restoring original DPUDeployment serviceChains switches")
		dpuDeployment.Spec.ServiceChains.Switches = originalSwitches
		Expect(mgmtClient.Update(ctx, dpuDeployment)).To(Succeed())

		By("Waiting for DPUServiceChain to reconcile back to the original path")
		Eventually(func(g Gomega) {
			chains := listOwnedDPUServiceChains()
			g.Expect(chains).NotTo(BeEmpty(), "expected at least one DPUServiceChain")
			for _, c := range chains {
				g.Expect(preRestoreChainUIDs[c.UID]).To(BeFalse(),
					"DPUServiceChain %s should have been replaced by the restore", c.Name)
				g.Expect(isReady(c.Status.Conditions)).To(BeTrue(),
					"DPUServiceChain %s should be Ready after restore", c.Name)
				g.Expect(c.Annotations[dpuServiceChainVersionAnnotation]).To(Equal(preSwapChainVersion),
					"DPUServiceChain version should match the original %q after restore", preSwapChainVersion)
			}
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(10 * time.Second).Should(Succeed())
	})

	It("should verify connectivity after restore", func() {
		hbnPods, err := discoverHBNPods(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace, dpuWorkers)
		Expect(err).NotTo(HaveOccurred())
		Expect(hbnPods).To(HaveLen(len(dpuWorkers)))

		workloadPods = rediscoverWorkloadPods()
		verifyWorkloadToHBNConnectivity(workloadPods, hbnPods)
	})

	It("should have a healthy cluster after service chain path update", func() {
		waitForClusterHealth()
	})
})

// switchesMatch reports whether two DPUDeploymentSwitch slices are
// equivalent for the purposes of the safety-net cleanup check (same length,
// same service interface name per switch in order).
func switchesMatch(a, b []dpuservicev1.DPUDeploymentSwitch) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		var ifaceA, ifaceB string
		for _, p := range a[i].Ports {
			if p.Service != nil {
				ifaceA = p.Service.InterfaceName
			}
		}
		for _, p := range b[i].Ports {
			if p.Service != nil {
				ifaceB = p.Service.InterfaceName
			}
		}
		if ifaceA != ifaceB {
			return false
		}
	}
	return true
}
