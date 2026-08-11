package e2e

import (
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/utils"
)

// TC-INST-003: Validate DPF on OCP 4.22.z Operates a Cluster with a Mix of DPU Workers and Non-DPU Workers
//
// Verifies that DPF correctly scopes DPU provisioning and services to DPU-enabled host
// worker nodes only, leaving regular (non-DPU) workers untouched and fully schedulable.
var _ = Describe("TC-INST-003: Validate DPF on OCP Operates a Cluster with a Mix of DPU Workers and Non-DPU Workers", Label("deployment", "installation-mixed-workers"), Ordered, func() {

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available, skipping TC-INST-003")
		}
	})

	It("pre-condition: should have both DPU-enabled and non-DPU worker nodes present", func() {
		By("Listing all ready worker nodes in management cluster")
		allWorkers, err := utils.GetReadyWorkerNodes(ctx, mgmtClient)
		Expect(err).NotTo(HaveOccurred())

		var dpuEnabledWorkers, nonDPUWorkers []corev1.Node
		for _, n := range allWorkers {
			if _, ok := n.Labels[utils.DPUEnabledLabel]; ok {
				dpuEnabledWorkers = append(dpuEnabledWorkers, n)
			} else {
				nonDPUWorkers = append(nonDPUWorkers, n)
			}
		}

		GinkgoWriter.Printf("Worker nodes — DPU-enabled: %d, non-DPU: %d (total: %d)\n",
			len(dpuEnabledWorkers), len(nonDPUWorkers), len(allWorkers))
		for _, n := range dpuEnabledWorkers {
			GinkgoWriter.Printf("  DPU-enabled: %s\n", n.Name)
		}
		for _, n := range nonDPUWorkers {
			GinkgoWriter.Printf("  non-DPU:     %s\n", n.Name)
		}

		Expect(dpuEnabledWorkers).NotTo(BeEmpty(),
			"cluster must have at least one DPU-enabled worker node")
		if len(nonDPUWorkers) == 0 {
			Skip("no non-DPU worker nodes found; TC-INST-003 requires a mixed-worker cluster")
		}
	})

	It("pre-condition: should have DPUDeployment in Ready state", func() {
		Eventually(func(g Gomega) {
			dpuDeployment := getDPUDeployment()
			g.Expect(isReady(dpuDeployment.Status.Conditions)).To(BeTrue(),
				"DPUDeployment must be Ready before mixed-worker cluster validation")
		}).WithTimeout(dpfe2e.DPUDeploymentReadyTimeout).WithPolling(5 * time.Second).Should(Succeed())
	})

	It("should have DPU objects provisioned only on DPU-enabled nodes", func() {
		By("Listing all DPU objects in DPF namespace")
		dpuList := &provisioningv1.DPUList{}
		Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())

		dpuEnabledNames := make(map[string]struct{}, len(dpuHostWorkers))
		for _, n := range dpuHostWorkers {
			dpuEnabledNames[n.Name] = struct{}{}
		}

		for _, dpu := range dpuList.Items {
			nodeName := dpu.Spec.DPUNodeName
			GinkgoWriter.Printf("DPU %s → node %s (phase: %s)\n", dpu.Name, nodeName, dpu.Status.Phase)
			Expect(dpuEnabledNames).To(HaveKey(nodeName),
				"DPU %s is on node %s which is not a DPU-enabled host worker; "+
					"DPU provisioning must not target non-DPU nodes in a mixed cluster",
				dpu.Name, nodeName)
		}
		GinkgoWriter.Printf("All %d DPU object(s) are confined to DPU-enabled nodes\n", len(dpuList.Items))
	})

	It("should have all DPU objects in Ready phase", func() {
		dpuList := &provisioningv1.DPUList{}
		Expect(mgmtClient.List(ctx, dpuList, client.InNamespace(cfg.DPFNamespace))).To(Succeed())

		dpuByNode := make(map[string]provisioningv1.DPU, len(dpuList.Items))
		for _, dpu := range dpuList.Items {
			dpuByNode[dpu.Spec.DPUNodeName] = dpu
		}

		for _, n := range dpuHostWorkers {
			dpu, ok := dpuByNode[n.Name]
			Expect(ok).To(BeTrue(),
				"no DPU object found for DPU-enabled worker node %s", n.Name)
			Expect(dpu.Status.Phase).To(Equal(provisioningv1.DPUReady),
				"DPU %s on node %s should be in Ready phase, got %q",
				dpu.Name, n.Name, dpu.Status.Phase)
			GinkgoWriter.Printf("DPU %s on node %s: Ready\n", dpu.Name, n.Name)
		}
		GinkgoWriter.Printf("%d DPU object(s) verified Ready (one per DPU-enabled worker)\n", len(dpuHostWorkers))
	})

	It("should have DPU worker nodes labeled with the worker-dpu role", func() {
		for _, n := range dpuHostWorkers {
			By(fmt.Sprintf("Checking node %s has worker-dpu role label", n.Name))
			Expect(n.Labels).To(HaveKey("node-role.kubernetes.io/worker-dpu"),
				"DPU host worker %s must have the worker-dpu role label; "+
					"the MCP assigns this label during DPU provisioning",
				n.Name)
		}
		GinkgoWriter.Printf("All %d DPU host worker(s) carry the worker-dpu role label\n", len(dpuHostWorkers))
	})

	It("should have Updated, non-Degraded MachineConfigPools for each worker type", func() {
		mcpList := &unstructured.UnstructuredList{}
		mcpList.SetGroupVersionKind(schema.GroupVersionKind{
			Group:   "machineconfiguration.openshift.io",
			Version: "v1",
			Kind:    "MachineConfigPoolList",
		})
		Expect(mgmtClient.List(ctx, mcpList)).To(Succeed())

		mcpByName := map[string]unstructured.Unstructured{}
		for _, mcp := range mcpList.Items {
			mcpByName[mcp.GetName()] = mcp
		}

		for _, poolName := range []string{"worker", "worker-dpu"} {
			By(fmt.Sprintf("Checking MachineConfigPool %q exists and is healthy", poolName))
			mcp, ok := mcpByName[poolName]
			Expect(ok).To(BeTrue(), "MachineConfigPool %q must exist in a mixed-worker cluster", poolName)

			conditions, _, _ := unstructured.NestedSlice(mcp.Object, "status", "conditions")
			var updating, degraded, updated bool
			for _, raw := range conditions {
				cond, _ := raw.(map[string]interface{})
				t, _, _ := unstructured.NestedString(cond, "type")
				s, _, _ := unstructured.NestedString(cond, "status")
				switch t {
				case "Updating":
					updating = s == "True"
				case "Degraded":
					degraded = s == "True"
				case "Updated":
					updated = s == "True"
				}
			}
			Expect(updating).To(BeFalse(),
				"MachineConfigPool %q must not be Updating", poolName)
			Expect(degraded).To(BeFalse(),
				"MachineConfigPool %q must not be Degraded", poolName)
			Expect(updated).To(BeTrue(),
				"MachineConfigPool %q must have Updated=True", poolName)

			mc, _, _ := unstructured.NestedInt64(mcp.Object, "status", "machineCount")
			ready, _, _ := unstructured.NestedInt64(mcp.Object, "status", "readyMachineCount")
			GinkgoWriter.Printf("MCP %q: machineCount=%d readyMachineCount=%d\n", poolName, mc, ready)
			Expect(ready).To(Equal(mc),
				"MachineConfigPool %q: readyMachineCount (%d) must equal machineCount (%d)",
				poolName, ready, mc)
		}

		By("Verifying worker-dpu MCP machine count matches DPU host worker count")
		dpuMCP := mcpByName["worker-dpu"]
		dpuMCPCount, _, _ := unstructured.NestedInt64(dpuMCP.Object, "status", "machineCount")
		Expect(int(dpuMCPCount)).To(Equal(len(dpuHostWorkers)),
			"worker-dpu MCP machineCount (%d) must equal the number of DPU host workers (%d)",
			dpuMCPCount, len(dpuHostWorkers))
	})

	It("should deploy workloads on non-DPU workers and verify east-west connectivity to DPU workers", func() {
		verifyMixedWorkerEastWestConnectivity()
	})

	It("should have no DPU-specific taints on non-DPU worker nodes", func() {
		By("Listing all ready worker nodes")
		allWorkers, err := utils.GetReadyWorkerNodes(ctx, mgmtClient)
		Expect(err).NotTo(HaveOccurred())

		dpuEnabledSet := make(map[string]struct{}, len(dpuHostWorkers))
		for _, n := range dpuHostWorkers {
			dpuEnabledSet[n.Name] = struct{}{}
		}

		for _, worker := range allWorkers {
			if _, isDPU := dpuEnabledSet[worker.Name]; isDPU {
				continue
			}
			By(fmt.Sprintf("Checking non-DPU worker %s for DPU-specific taints", worker.Name))
			for _, taint := range worker.Spec.Taints {
				Expect(taint.Key).NotTo(HavePrefix("dpu.nvidia.com/"),
					"non-DPU worker %s must not carry DPU-specific taint %q (value=%q, effect=%q); "+
						"DPU taints must be confined to DPU-enabled nodes",
					worker.Name, taint.Key, taint.Value, taint.Effect)
			}
			GinkgoWriter.Printf("Non-DPU worker %s: no DPU-specific taints\n", worker.Name)
		}
	})

	It("should have a healthy cluster in mixed-worker configuration", func() {
		waitForClusterHealth()
	})
})
