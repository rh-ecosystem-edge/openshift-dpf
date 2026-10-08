package e2e

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpfe2e "github.com/nvidia/doca-platform/test/e2e"

	provisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
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
	var (
		existingWorkerNames      map[string]struct{}
		temporaryWorkerNodeNames map[string]struct{}
		temporaryWorkerVMPrefix  string
		createdCSRApproverByTest bool
	)

	BeforeAll(func() {
		if dpfInput.NumberOfDPUNodes == 0 {
			Skip("No DPU nodes available, skipping TC-INST-003")
		}

		allWorkers, err := utils.GetWorkerNodes(ctx, mgmtClient)
		Expect(err).NotTo(HaveOccurred())

		existingWorkerNames = workerNodeNames(allWorkers)
		readyWorkers, err := utils.GetReadyWorkerNodes(ctx, mgmtClient)
		Expect(err).NotTo(HaveOccurred())
		if hasNonDPUWorker(readyWorkers) {
			GinkgoWriter.Printf("Found an existing Ready non-DPU worker; no temporary worker is required\n")
			return
		}

		temporaryWorkerVMPrefix = fmt.Sprintf("dpf-mixed-test-%d-", time.Now().UnixNano())
		temporaryWorkerNodeNames = make(map[string]struct{})

		// Register cleanup before provisioning so VMs and any worker nodes discovered
		// before the Make target or a later assertion fails are removed.
		csrApprover := &batchv1.CronJob{}
		err = mgmtClient.Get(ctx, client.ObjectKey{
			Namespace: "openshift-machine-api",
			Name:      "csr-auto-approver",
		}, csrApprover)
		if err != nil && !apierrors.IsNotFound(err) {
			Expect(err).NotTo(HaveOccurred(), "failed to check for the existing CSR auto-approver")
		}
		csrApproverExisted := err == nil
		createdCSRApproverByTest = !csrApproverExisted

		DeferCleanup(func() {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()

			cleanupErrs := cleanupTemporaryMixedWorker(
				cleanupCtx,
				mgmtClient,
				temporaryWorkerNodeNames,
				temporaryWorkerVMPrefix,
				createdCSRApproverByTest,
			)
			Expect(cleanupErrs).To(BeEmpty(), "temporary mixed-worker cleanup failures")
		})

		By(fmt.Sprintf("Adding one temporary regular VM worker with prefix %s", temporaryWorkerVMPrefix))
		err = runMakeTarget(ctx,
			"VM_WORKER_COUNT=1",
			"VM_WORKER_PREFIX="+temporaryWorkerVMPrefix,
			"AUTO_APPROVE_WORKER_CSR=true",
			"add-vm-workers",
		)
		if err != nil {
			workers, listErr := utils.GetWorkerNodes(ctx, mgmtClient)
			if listErr != nil {
				GinkgoWriter.Printf("Could not discover temporary worker Nodes after provisioning failure: %v\n", listErr)
			} else {
				recordTemporaryWorkerNodes(workers, existingWorkerNames, temporaryWorkerNodeNames)
			}
		}
		Expect(err).NotTo(HaveOccurred(), "failed to add a temporary regular VM worker")

		By("Waiting for the temporary regular VM worker to become Ready")
		Eventually(func(g Gomega) {
			workers, listErr := utils.GetWorkerNodes(ctx, mgmtClient)
			g.Expect(listErr).NotTo(HaveOccurred())

			recordTemporaryWorkerNodes(workers, existingWorkerNames, temporaryWorkerNodeNames)

			newRegularReadyWorkers := make([]corev1.Node, 0)
			for _, worker := range workers {
				if _, existed := existingWorkerNames[worker.Name]; existed {
					continue
				}
				if hasDPUEnabledLabel(worker) {
					continue
				}
				if isNodeReady(worker) {
					newRegularReadyWorkers = append(newRegularReadyWorkers, worker)
				}
			}
			g.Expect(newRegularReadyWorkers).NotTo(BeEmpty(),
				"no newly-added non-DPU worker is Ready")
		}).WithTimeout(30 * time.Minute).WithPolling(30 * time.Second).Should(Succeed())
		GinkgoWriter.Printf("Temporary regular worker node(s): %v\n", sortedWorkerNames(temporaryWorkerNodeNames))
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
		Expect(nonDPUWorkers).NotTo(BeEmpty(),
			"cluster must have at least one non-DPU worker node after mixed-worker setup")
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
		var mcpByName map[string]unstructured.Unstructured

		By("Waiting for worker and worker-dpu MachineConfigPools to settle")
		Eventually(func(g Gomega) {
			mcpList := &unstructured.UnstructuredList{}
			mcpList.SetGroupVersionKind(schema.GroupVersionKind{
				Group:   "machineconfiguration.openshift.io",
				Version: "v1",
				Kind:    "MachineConfigPoolList",
			})
			g.Expect(mgmtClient.List(ctx, mcpList)).To(Succeed())

			mcpByName = map[string]unstructured.Unstructured{}
			for _, mcp := range mcpList.Items {
				mcpByName[mcp.GetName()] = mcp
			}

			for _, poolName := range []string{"worker", "worker-dpu"} {
				mcp, ok := mcpByName[poolName]
				g.Expect(ok).To(BeTrue(), "MachineConfigPool %q must exist in a mixed-worker cluster", poolName)
				if !ok {
					return
				}

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
				g.Expect(updating).To(BeFalse(),
					"MachineConfigPool %q must not be Updating", poolName)
				g.Expect(degraded).To(BeFalse(),
					"MachineConfigPool %q must not be Degraded", poolName)
				g.Expect(updated).To(BeTrue(),
					"MachineConfigPool %q must have Updated=True", poolName)

				mc, _, _ := unstructured.NestedInt64(mcp.Object, "status", "machineCount")
				ready, _, _ := unstructured.NestedInt64(mcp.Object, "status", "readyMachineCount")
				GinkgoWriter.Printf("MCP %q: machineCount=%d readyMachineCount=%d updating=%t degraded=%t updated=%t\n",
					poolName, mc, ready, updating, degraded, updated)
				g.Expect(ready).To(Equal(mc),
					"MachineConfigPool %q: readyMachineCount (%d) must equal machineCount (%d)",
					poolName, ready, mc)
			}
		}).WithTimeout(30 * time.Minute).WithPolling(10 * time.Second).Should(Succeed())

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

func runMakeTarget(ctx context.Context, args ...string) error {
	makeArgs := append([]string{"-C", repositoryRoot()}, args...)
	cmd := exec.CommandContext(ctx, "make", makeArgs...)
	cmd.Stdout = GinkgoWriter
	cmd.Stderr = GinkgoWriter
	return cmd.Run()
}

func repositoryRoot() string {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		return "."
	}
	return filepath.Clean(filepath.Join(filepath.Dir(sourceFile), "..", ".."))
}

func workerNodeNames(workers []corev1.Node) map[string]struct{} {
	names := make(map[string]struct{}, len(workers))
	for _, worker := range workers {
		names[worker.Name] = struct{}{}
	}
	return names
}

func hasNonDPUWorker(workers []corev1.Node) bool {
	for _, worker := range workers {
		if !hasDPUEnabledLabel(worker) {
			return true
		}
	}
	return false
}

func hasDPUEnabledLabel(node corev1.Node) bool {
	_, enabled := node.Labels[utils.DPUEnabledLabel]
	return enabled
}

func recordTemporaryWorkerNodes(
	workers []corev1.Node,
	existingWorkerNames map[string]struct{},
	temporaryWorkerNodeNames map[string]struct{},
) {
	for _, worker := range workers {
		if _, existed := existingWorkerNames[worker.Name]; existed {
			continue
		}
		if hasDPUEnabledLabel(worker) {
			continue
		}
		// Record the Node as soon as it registers, even if it is not Ready yet.
		temporaryWorkerNodeNames[worker.Name] = struct{}{}
	}
}

func isNodeReady(node corev1.Node) bool {
	for _, condition := range node.Status.Conditions {
		if condition.Type == corev1.NodeReady && condition.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func sortedWorkerNames(names map[string]struct{}) []string {
	result := make([]string, 0, len(names))
	for name := range names {
		result = append(result, name)
	}
	sort.Strings(result)
	return result
}

func cleanupTemporaryMixedWorker(
	ctx context.Context,
	c client.Client,
	temporaryWorkerNodeNames map[string]struct{},
	temporaryWorkerVMPrefix string,
	removeCSRApprover bool,
) []error {
	cleanupErrs := make([]error, 0)

	for nodeName := range temporaryWorkerNodeNames {
		node := &corev1.Node{}
		err := c.Get(ctx, client.ObjectKey{Name: nodeName}, node)
		if apierrors.IsNotFound(err) {
			continue
		}
		if err != nil {
			cleanupErrs = append(cleanupErrs, fmt.Errorf("getting temporary worker node %s: %w", nodeName, err))
			continue
		}
		if err := c.Delete(ctx, node); err != nil && !apierrors.IsNotFound(err) {
			cleanupErrs = append(cleanupErrs, fmt.Errorf("deleting temporary worker node %s: %w", nodeName, err))
		} else {
			GinkgoWriter.Printf("Deleted temporary worker node %s\n", nodeName)
		}
	}

	if temporaryWorkerVMPrefix != "" {
		if err := runMakeTarget(ctx, "VM_WORKER_PREFIX="+temporaryWorkerVMPrefix, "delete-worker-vms"); err != nil {
			cleanupErrs = append(cleanupErrs, fmt.Errorf("deleting temporary worker VMs: %w", err))
		}
	}

	if removeCSRApprover {
		if err := runMakeTarget(ctx, "delete-csr-approver"); err != nil {
			cleanupErrs = append(cleanupErrs, fmt.Errorf("removing test-created CSR auto-approver: %w", err))
		}
	}

	return cleanupErrs
}
