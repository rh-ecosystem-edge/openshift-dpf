package e2e

import (
	"encoding/binary"
	"fmt"
	"net"
	"reflect"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
	nvipamv1 "github.com/nvidia/doca-platform/third_party/api/nvipam/api/v1alpha1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	tcSvc004DPUServiceIPAMName = "pool1"
)

func expectedCIDRPoolGateway(prefix string, gatewayIndex int32) (string, error) {
	if gatewayIndex < 0 {
		return "", fmt.Errorf("gateway index must not be negative: %d", gatewayIndex)
	}

	_, subnet, err := net.ParseCIDR(prefix)
	if err != nil {
		return "", fmt.Errorf("parsing allocation prefix %q: %w", prefix, err)
	}
	networkIP := subnet.IP.To4()
	if networkIP == nil {
		return "", fmt.Errorf("allocation prefix %q is not IPv4", prefix)
	}

	base := binary.BigEndian.Uint32(networkIP)
	offset := uint32(gatewayIndex)
	if offset > ^uint32(0)-base {
		return "", fmt.Errorf("gateway index %d overflows allocation prefix %q", gatewayIndex, prefix)
	}

	gatewayIP := make(net.IP, net.IPv4len)
	binary.BigEndian.PutUint32(gatewayIP, base+offset)
	if !subnet.Contains(gatewayIP) {
		return "", fmt.Errorf("gateway index %d falls outside allocation prefix %q", gatewayIndex, prefix)
	}
	return gatewayIP.String(), nil
}

func validateCIDRPoolGateways(pool *nvipamv1.CIDRPool, gatewayIndex int32) error {
	for _, allocation := range pool.Status.Allocations {
		expectedGateway, err := expectedCIDRPoolGateway(allocation.Prefix, gatewayIndex)
		if err != nil {
			return fmt.Errorf("computing gateway for node %s: %w", allocation.NodeName, err)
		}
		if allocation.Gateway != expectedGateway {
			return fmt.Errorf("node %s with prefix %s has gateway %s, want %s for gatewayIndex %d",
				allocation.NodeName, allocation.Prefix, allocation.Gateway, expectedGateway, gatewayIndex)
		}
	}
	return nil
}

// TC-SVC-004: Edit DPUServiceIPAM Object
//
// Updates pool1's gatewayIndex and verifies that hbn gateway addresses change.
// Existing HBN pods keep their current IPs after the IPAM edit;
// after reprovisioning one DPU, its new HBN pod must use the updated gateway.
// Cleanup restores the original IPAM configuration, reprovisions the target DPU
// so its routes use the original gateway, and recreates any HBN pod whose address changed.
var _ = Describe("TC-SVC-004: Edit DPUServiceIPAM Object",
	Label("dpuservice", "update-dpuserviceipam"), Ordered, func() {
		var (
			originalIPAMSpec      dpuservicev1.DPUServiceIPAMSpec
			originalCIDRPool      *nvipamv1.CIDRPool
			originalHBNPods       map[string]HBNPodInfo
			targetDPU             provisioningv1.DPU
			updatedGatewayIndex   int32
			updatedTargetIP       string
			originalStateCaptured bool
			targetDPUDeleted      bool
		)

		BeforeAll(func() {
			skipIfClusterNotReadyForDPUReprovisioning()
		})

		AfterAll(func() {
			if !originalStateCaptured {
				return
			}

			current := &dpuservicev1.DPUServiceIPAM{}
			Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      tcSvc004DPUServiceIPAMName,
			}, current)).To(Succeed(), "AfterAll: failed to get pool1 DPUServiceIPAM")

			if !reflect.DeepEqual(current.Spec, originalIPAMSpec) {
				By("AfterAll: restoring the original pool1 DPUServiceIPAM spec")
				patch := client.MergeFrom(current.DeepCopy())
				current.Spec = *originalIPAMSpec.DeepCopy()
				Expect(mgmtClient.Patch(ctx, current, patch)).To(Succeed(),
					"AfterAll: failed to restore pool1 DPUServiceIPAM")
			}

			By("AfterAll: waiting for the original pool1 CIDRPool configuration")
			Eventually(func(g Gomega) {
				ipam := &dpuservicev1.DPUServiceIPAM{}
				g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      tcSvc004DPUServiceIPAMName,
				}, ipam)).To(Succeed())
				g.Expect(ipam.Spec).To(Equal(originalIPAMSpec))
				g.Expect(ipam.Status.ObservedGeneration).To(BeNumerically(">=", ipam.Generation))
				g.Expect(isReady(ipam.Status.Conditions)).To(BeTrue())

				pool := &nvipamv1.CIDRPool{}
				g.Expect(hostedClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      tcSvc004DPUServiceIPAMName,
				}, pool)).To(Succeed())
				g.Expect(pool.Spec).To(Equal(originalCIDRPool.Spec))
				g.Expect(pool.Status.Allocations).To(Equal(originalCIDRPool.Status.Allocations))
			}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

			if targetDPUDeleted {
				By("AfterAll: deleting the DPU again so it provisions with the original pool1 gateway")
				dpuToDelete := &provisioningv1.DPU{}
				err := mgmtClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      targetDPU.Name,
				}, dpuToDelete)
				dpuUIDToReplace := targetDPU.UID
				if err == nil {
					dpuUIDToReplace = dpuToDelete.UID
					Expect(mgmtClient.Delete(ctx, dpuToDelete)).To(Succeed(),
						"AfterAll: failed to delete DPU %s for reprovisioning with the original gateway", targetDPU.Name)
				} else {
					Expect(client.IgnoreNotFound(err)).To(Succeed(),
						"AfterAll: failed to get DPU %s before reprovisioning", targetDPU.Name)
				}

				By("AfterAll: waiting for the DPU to be recreated and Ready with the original pool1 gateway")
				Eventually(func(g Gomega) {
					recreatedDPU := &provisioningv1.DPU{}
					g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
						Namespace: cfg.DPFNamespace,
						Name:      targetDPU.Name,
					}, recreatedDPU)).To(Succeed())
					g.Expect(recreatedDPU.UID).NotTo(Equal(dpuUIDToReplace),
						"DPU must be recreated with a new UID after cleanup deletes it")
					g.Expect(recreatedDPU.Status.Phase).To(Equal(provisioningv1.DPUReady),
						"recreated DPU must be Ready after restoring the original gateway")
				}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

				waitForClusterHealthAfterDPUReprovisioning()
			} else {
				waitForClusterHealth()
			}

			for dpuNodeName, originalPod := range originalHBNPods {
				var currentPod HBNPodInfo
				Eventually(func(g Gomega) {
					currentPods, err := discoverHBNPodsByDPUNode(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace)
					g.Expect(err).NotTo(HaveOccurred())
					var exists bool
					currentPod, exists = currentPods[dpuNodeName]
					g.Expect(exists).To(BeTrue(), "HBN pod for DPU node %s must exist during cleanup", dpuNodeName)
				}).WithTimeout(5 * time.Minute).WithPolling(15 * time.Second).Should(Succeed())

				if currentPod.IP == originalPod.IP {
					continue
				}

				By(fmt.Sprintf("AfterAll: recreating HBN pod on DPU node %s to restore its original pool1 address %s",
					dpuNodeName, originalPod.IP))
				deletePodAndWait(ctx, hostedClient, currentPod.Namespace, currentPod.Name, currentPod.UID)
				waitForHBNPodByDPUNode(ctx, hostedClient, hostedConfig, hostedClientset,
					cfg.DPFNamespace, dpuNodeName, currentPod.UID, originalPod.IP)
			}

			waitForClusterHealth()
		})

		It("pre-condition: should have ready pool1 allocations on HBN pods", func() {
			waitForClusterHealth()

			ipam := &dpuservicev1.DPUServiceIPAM{}
			Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      tcSvc004DPUServiceIPAMName,
			}, ipam)).To(Succeed(), "pool1 DPUServiceIPAM must exist")
			Expect(ipam.Spec.IPV4Network).NotTo(BeNil(),
				"pool1 DPUServiceIPAM must use ipv4Network")
			Expect(ipam.Spec.IPV4Network.Network).NotTo(BeEmpty(),
				"pool1 DPUServiceIPAM network must be set")
			Expect(ipam.Spec.IPV4Network.GatewayIndex).NotTo(BeNil(),
				"pool1 DPUServiceIPAM must configure a gateway for HBN")
			Expect(ipam.Spec.IPV4Network.PrefixSize).To(Equal(int32(29)),
				"TC-SVC-004 gateway-index update expects pool1 /29 allocations")
			Expect(isReady(ipam.Status.Conditions)).To(BeTrue(),
				"pool1 DPUServiceIPAM must be Ready before update")

			pool := &nvipamv1.CIDRPool{}
			Eventually(func(g Gomega) {
				g.Expect(hostedClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      tcSvc004DPUServiceIPAMName,
				}, pool)).To(Succeed())
				g.Expect(pool.Spec.CIDR).To(Equal(ipam.Spec.IPV4Network.Network))
				g.Expect(pool.Spec.GatewayIndex).NotTo(BeNil())
				g.Expect(*pool.Spec.GatewayIndex).To(Equal(*ipam.Spec.IPV4Network.GatewayIndex))
				g.Expect(pool.Status.Allocations).NotTo(BeEmpty(),
					"pool1 CIDRPool must have existing allocations")
			}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

			pods, err := discoverHBNPodsByDPUNode(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace)
			Expect(err).NotTo(HaveOccurred())
			Expect(pods).NotTo(BeEmpty(), "no HBN pods found on DPU nodes")
			for dpuNodeName, pod := range pods {
				allocation, found := cidrPoolAllocationForNode(pool, pod.NodeName)
				Expect(found).To(BeTrue(), "pool1 must have an allocation for hosted node %s (DPU node %s)",
					pod.NodeName, dpuNodeName)
				Expect(pod.IP).To(Equal(allocation.Gateway),
					"HBN on DPU node %s must use its pool1 gateway address", dpuNodeName)
				Expect(cidrPoolContainsIP(pool, pod.IP)).To(BeTrue(),
					"pool1 CIDRPool must contain HBN IP %s on DPU node %s", pod.IP, dpuNodeName)
			}

			originalIPAMSpec = *ipam.Spec.DeepCopy()
			originalCIDRPool = pool.DeepCopy()
			originalHBNPods = pods
			targetDPU, err = findReadyDPUWithHBNPod(ctx, mgmtClient, cfg.DPFNamespace, pods)
			Expect(err).NotTo(HaveOccurred())
			originalGatewayIndex := *ipam.Spec.IPV4Network.GatewayIndex
			updatedGatewayIndex = originalGatewayIndex + 1
			addressesPerPrefix := int32(1) << uint32(32-ipam.Spec.IPV4Network.PrefixSize)
			lastUsableGatewayIndex := addressesPerPrefix - 2
			Expect(updatedGatewayIndex).To(BeNumerically("<=", lastUsableGatewayIndex),
				"incremented pool1 gatewayIndex must remain before the /29 broadcast address")
			Expect(updatedGatewayIndex).To(BeNumerically(">", 1),
				"updated pool1 gatewayIndex must not overlap OVN's configured IP indexes 0 and 1")
			GinkgoWriter.Printf("pool1 gatewayIndex: %d -> %d\n",
				originalGatewayIndex, updatedGatewayIndex)
			originalStateCaptured = true
		})

		It("should update pool1 gatewayIndex without changing existing HBN pods", func() {
			ipam := &dpuservicev1.DPUServiceIPAM{}
			Expect(mgmtClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      tcSvc004DPUServiceIPAMName,
			}, ipam)).To(Succeed())
			Expect(ipam.Spec).To(Equal(originalIPAMSpec))

			expectedIPAMSpec := originalIPAMSpec.DeepCopy()
			expectedIPAMSpec.IPV4Network.GatewayIndex = &updatedGatewayIndex
			expectedCIDRPool := originalCIDRPool.DeepCopy()
			expectedCIDRPool.Spec.GatewayIndex = &updatedGatewayIndex

			By(fmt.Sprintf("Changing pool1 gatewayIndex to %d", updatedGatewayIndex))
			patch := client.MergeFrom(ipam.DeepCopy())
			ipam.Spec.IPV4Network.GatewayIndex = &updatedGatewayIndex
			Expect(mgmtClient.Patch(ctx, ipam, patch)).To(Succeed())

			By("Waiting for gatewayIndex to be reconciled to the DPUCluster CIDRPool")
			Eventually(func(g Gomega) {
				currentIPAM := &dpuservicev1.DPUServiceIPAM{}
				g.Expect(mgmtClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      tcSvc004DPUServiceIPAMName,
				}, currentIPAM)).To(Succeed())
				g.Expect(currentIPAM.Spec).To(Equal(*expectedIPAMSpec))
				g.Expect(currentIPAM.Status.ObservedGeneration).To(BeNumerically(">=", currentIPAM.Generation))
				g.Expect(isReady(currentIPAM.Status.Conditions)).To(BeTrue())

				pool := &nvipamv1.CIDRPool{}
				g.Expect(hostedClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      tcSvc004DPUServiceIPAMName,
				}, pool)).To(Succeed())
				g.Expect(pool.Spec).To(Equal(expectedCIDRPool.Spec))
				g.Expect(cidrPoolAllocationPrefixes(pool)).To(Equal(cidrPoolAllocationPrefixes(originalCIDRPool)),
					"changing gatewayIndex must not change per-node CIDR allocations")
				g.Expect(validateCIDRPoolGateways(pool, updatedGatewayIndex)).To(Succeed())

				targetPod := originalHBNPods[targetDPU.Spec.DPUNodeName]
				allocation, found := cidrPoolAllocationForNode(pool, targetPod.NodeName)
				g.Expect(found).To(BeTrue(), "pool1 must retain an allocation for hosted node %s",
					targetPod.NodeName)
				expectedTargetIP, err := expectedCIDRPoolGateway(allocation.Prefix, updatedGatewayIndex)
				g.Expect(err).NotTo(HaveOccurred(), "computing updated gateway for target HBN node %s", targetPod.NodeName)
				g.Expect(allocation.Gateway).To(Equal(expectedTargetIP),
					"target allocation must use the address selected by the updated gatewayIndex")
				g.Expect(expectedTargetIP).NotTo(Equal(originalHBNPods[targetDPU.Spec.DPUNodeName].IP),
					"updated gateway must differ from the target HBN's original IP")
				updatedTargetIP = expectedTargetIP
			}).WithTimeout(5 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

			By("Verifying existing HBN pods retain their IPs and identities")
			Eventually(func(g Gomega) {
				currentPods, err := discoverHBNPodsByDPUNode(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace)
				g.Expect(err).NotTo(HaveOccurred())
				for dpuNodeName, originalPod := range originalHBNPods {
					currentPod, exists := currentPods[dpuNodeName]
					g.Expect(exists).To(BeTrue(), "existing DPU node %s must retain an HBN pod", dpuNodeName)
					g.Expect(currentPod.UID).To(Equal(originalPod.UID),
						"existing HBN pod on DPU node %s must not be replaced by an IPAM update", dpuNodeName)
					g.Expect(currentPod.IP).To(Equal(originalPod.IP),
						"existing HBN pod on DPU node %s must retain its IP", dpuNodeName)
				}
			}).WithTimeout(5 * time.Minute).WithPolling(15 * time.Second).Should(Succeed())
		})

		It("should provision a DPU with the updated pool1 gateway address", func() {
			oldTargetPod := originalHBNPods[targetDPU.Spec.DPUNodeName]
			By(fmt.Sprintf("Deleting DPU %s to trigger a new provisioning cycle", targetDPU.Name))
			Expect(mgmtClient.Delete(ctx, &targetDPU)).To(Succeed())
			targetDPUDeleted = true

			By("Waiting for the replacement DPU to become Ready")
			var replacementDPU provisioningv1.DPU
			Eventually(func(g Gomega) {
				current := &provisioningv1.DPU{}
				err := mgmtClient.Get(ctx, client.ObjectKey{
					Namespace: cfg.DPFNamespace,
					Name:      targetDPU.Name,
				}, current)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(current.UID).NotTo(Equal(targetDPU.UID), "DPU must be recreated with a new UID")
				g.Expect(current.Status.Phase).To(Equal(provisioningv1.DPUReady),
					"replacement DPU must be Ready")
				replacementDPU = *current.DeepCopy()
			}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(30 * time.Second).Should(Succeed())

			waitForClusterHealthAfterDPUReprovisioning()

			By("Verifying the replacement HBN pod receives the updated pool1 gateway address")
			updatedTargetPod := waitForHBNPodByDPUNode(ctx, hostedClient, hostedConfig, hostedClientset,
				cfg.DPFNamespace, replacementDPU.Spec.DPUNodeName, oldTargetPod.UID, updatedTargetIP)
			Expect(updatedTargetPod.IP).NotTo(Equal(oldTargetPod.IP),
				"replacement HBN pod must use the updated pool1 gateway address")

			pool := &nvipamv1.CIDRPool{}
			Expect(hostedClient.Get(ctx, client.ObjectKey{
				Namespace: cfg.DPFNamespace,
				Name:      tcSvc004DPUServiceIPAMName,
			}, pool)).To(Succeed())
			expectedCIDRPool := originalCIDRPool.DeepCopy()
			expectedCIDRPool.Spec.GatewayIndex = &updatedGatewayIndex
			Expect(pool.Spec).To(Equal(expectedCIDRPool.Spec))
			Expect(validateCIDRPoolGateways(pool, updatedGatewayIndex)).To(Succeed())
			allocation, found := cidrPoolAllocationForNode(pool, updatedTargetPod.NodeName)
			Expect(found).To(BeTrue(), "pool1 must retain an allocation for hosted node %s",
				updatedTargetPod.NodeName)
			expectedTargetIP, err := expectedCIDRPoolGateway(allocation.Prefix, updatedGatewayIndex)
			Expect(err).NotTo(HaveOccurred(), "computing updated gateway for target HBN node %s", updatedTargetPod.NodeName)
			Expect(allocation.Gateway).To(Equal(expectedTargetIP),
				"target allocation must use the address selected by the updated gatewayIndex")
			Expect(updatedTargetPod.IP).To(Equal(expectedTargetIP),
				"replacement HBN IP must be the updated pool1 gateway")
			Expect(cidrPoolAllocationPrefixes(pool)).To(Equal(cidrPoolAllocationPrefixes(originalCIDRPool)),
				"reprovisioning with a new gatewayIndex must preserve per-node CIDR allocations")

			currentPods, err := discoverHBNPodsByDPUNode(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace)
			Expect(err).NotTo(HaveOccurred())
			for dpuNodeName, originalPod := range originalHBNPods {
				if dpuNodeName == targetDPU.Spec.DPUNodeName {
					continue
				}
				currentPod, exists := currentPods[dpuNodeName]
				Expect(exists).To(BeTrue(), "existing DPU node %s must retain an HBN pod", dpuNodeName)
				Expect(currentPod.UID).To(Equal(originalPod.UID),
					"unreprovisioned HBN pod on DPU node %s must not be replaced", dpuNodeName)
				Expect(currentPod.IP).To(Equal(originalPod.IP),
					"unreprovisioned HBN pod on DPU node %s must retain its IP", dpuNodeName)
			}
		})

		It("should have a healthy cluster after the IPAM edit and DPU reprovisioning", func() {
			waitForClusterHealth()
		})
	})
