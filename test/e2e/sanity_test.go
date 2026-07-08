package e2e

import (
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/manifests"
	"github.com/openshift-dpf/test/utils"
)

var _ = Describe("Sanity Tests", Label("sanity"), Ordered, func() {
	var (
		hbnPods      []PodInfo
		workloadPods *WorkloadPods
	)

	Describe("Cluster Health", func() {
		It("should have no degraded or progressing cluster operators on management cluster", func() {
			checkClusterOperatorsHealthy(mgmtClient, "management")
		})

		It("should have no degraded or progressing cluster operators on hosted cluster", func() {
			checkClusterOperatorsHealthy(hostedClient, "hosted")
		})
	})

	Describe("Workload Setup", Ordered, func() {
		It("should deploy workload pods", func() {
			By("Applying workload manifests to management cluster")
			err := utils.ApplyManifests(ctx, mgmtClient, manifests.WorkloadManifestBytes())
			Expect(err).NotTo(HaveOccurred(), "failed to apply workload manifests")

			By("Waiting for all workload deployments to be ready")
			err = utils.WaitForDeployments(ctx, mgmtClient, cfg.WorkloadNamespace, 5*time.Minute)
			Expect(err).NotTo(HaveOccurred(), "workload deployments not ready")
		})

		It("should have all DPF operator pods running on management cluster", func() {
			pods, err := utils.GetRunningPods(ctx, mgmtClient, cfg.DPFNamespace, nil)
			Expect(err).NotTo(HaveOccurred())
			Expect(pods).NotTo(BeEmpty(), "no running pods found in %s on management cluster", cfg.DPFNamespace)
			GinkgoWriter.Printf("Found %d running pods in %s on management cluster\n", len(pods), cfg.DPFNamespace)
		})

		It("should have all DPF operator pods running on hosted cluster", func() {
			pods, err := utils.GetRunningPods(ctx, hostedClient, cfg.DPFNamespace, nil)
			Expect(err).NotTo(HaveOccurred())
			Expect(pods).NotTo(BeEmpty(), "no running pods found in %s on hosted cluster", cfg.DPFNamespace)
			GinkgoWriter.Printf("Found %d running pods in %s on hosted cluster\n", len(pods), cfg.DPFNamespace)
		})

		It("should discover DOCA-HBN pods on all DPU worker nodes", func() {
			Expect(dpuWorkers).NotTo(BeEmpty(), "no DPU worker nodes discovered")

			var err error
			hbnPods, err = discoverHBNPods(ctx, hostedClient, hostedConfig, hostedClientset, cfg.DPFNamespace, dpuWorkers)
			Expect(err).NotTo(HaveOccurred())
			Expect(hbnPods).To(HaveLen(len(dpuWorkers)))

			for _, p := range hbnPods {
				GinkgoWriter.Printf("HBN pod %s on node %s, IP=%s\n", p.Name, p.NodeName, p.IP)
			}
		})

		It("should discover workload test pods on all DPU host workers", func() {
			Expect(dpuHostWorkers).NotTo(BeEmpty(), "no DPU-enabled host worker nodes discovered")

			var err error
			workloadPods, err = discoverWorkloadPods(ctx, mgmtClient, cfg.WorkloadNamespace, dpuHostWorkers)
			Expect(err).NotTo(HaveOccurred())

			GinkgoWriter.Printf("Master pod: %s\n", workloadPods.Master.Name)
			for i, w := range workloadPods.Workers {
				GinkgoWriter.Printf("Worker pod[%d]: %s on %s\n", i, w.Name, w.Spec.NodeName)
			}
			for i, h := range workloadPods.HostNetWorkers {
				GinkgoWriter.Printf("HostNet pod[%d]: %s on %s\n", i, h.Name, h.Spec.NodeName)
			}
		})
	})

	Describe("Network Connectivity", Ordered, func() {
		BeforeAll(func() {
			Expect(hbnPods).NotTo(BeEmpty(), "HBN pods not discovered — Workload Setup must run first")
			Expect(workloadPods).NotTo(BeNil(), "workload pods not discovered — Workload Setup must run first")
		})

		It("should ping from master pod to each HBN pod (MTU 1490)", func() {
			for _, hbn := range hbnPods {
				By(fmt.Sprintf("Pinging from %s to HBN %s (IP=%s) MTU 1490", workloadPods.Master.Name, hbn.Name, hbn.IP))
				err := utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
					cfg.WorkloadNamespace, workloadPods.Master.Name, "nginx",
					hbn.IP, cfg.PingCount, 1490)
				Expect(err).NotTo(HaveOccurred())
			}
		})

		It("should ping from each worker pod to its same-node HBN pod (MTU 1490)", func() {
			for i, worker := range workloadPods.Workers {
				By(fmt.Sprintf("Pinging from %s to HBN %s (IP=%s) MTU 1490", worker.Name, hbnPods[i].Name, hbnPods[i].IP))
				err := utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
					cfg.WorkloadNamespace, worker.Name, "nginx",
					hbnPods[i].IP, cfg.PingCount, 1490)
				Expect(err).NotTo(HaveOccurred())
			}
		})

		It("should ping from each hostnetwork worker pod to its HBN pod (MTU 1490)", func() {
			for i, hnw := range workloadPods.HostNetWorkers {
				By(fmt.Sprintf("Pinging from %s to HBN %s (IP=%s) MTU 1490", hnw.Name, hbnPods[i].Name, hbnPods[i].IP))
				err := utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
					cfg.WorkloadNamespace, hnw.Name, "nginx",
					hbnPods[i].IP, cfg.PingCount, 1490)
				Expect(err).NotTo(HaveOccurred())
			}
		})

		It("should ping from each hostnetwork worker pod to its HBN pod (MTU 8970 jumbo)", func() {
			for i, hnw := range workloadPods.HostNetWorkers {
				By(fmt.Sprintf("Pinging from %s to HBN %s (IP=%s) MTU 8970", hnw.Name, hbnPods[i].Name, hbnPods[i].IP))
				err := utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
					cfg.WorkloadNamespace, hnw.Name, "nginx",
					hbnPods[i].IP, cfg.PingCount, 8970)
				Expect(err).NotTo(HaveOccurred())
			}
		})

		It("should ping external internet (8.8.8.8) from each worker pod", func() {
			for _, worker := range workloadPods.Workers {
				By(fmt.Sprintf("Pinging 8.8.8.8 from %s", worker.Name))
				err := utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
					cfg.WorkloadNamespace, worker.Name, "nginx",
					"8.8.8.8", cfg.PingCount, 0)
				Expect(err).NotTo(HaveOccurred())
			}
		})

		It("should ping external internet (8.8.8.8) from each hostnetwork worker pod", func() {
			for _, hnw := range workloadPods.HostNetWorkers {
				By(fmt.Sprintf("Pinging 8.8.8.8 from %s", hnw.Name))
				err := utils.PingFromPod(ctx, mgmtConfig, mgmtClientset,
					cfg.WorkloadNamespace, hnw.Name, "nginx",
					"8.8.8.8", cfg.PingCount, 0)
				Expect(err).NotTo(HaveOccurred())
			}
		})

		Context("HBN-to-HBN cross-node", func() {
			BeforeAll(func() {
				if !cfg.PingHBNToHBN {
					Skip("HBN-to-HBN ping tests disabled (set -ping-hbn-to-hbn=true to enable)")
				}
				if len(hbnPods) < 2 {
					Skip(fmt.Sprintf("Need at least 2 DPU workers for HBN-to-HBN tests, got %d", len(hbnPods)))
				}
			})

			It("should ping between HBN pods cross-node (MTU 1490)", Label("hbn"), func() {
				By(fmt.Sprintf("Pinging from HBN %s to HBN %s (IP=%s) MTU 1490", hbnPods[0].Name, hbnPods[1].Name, hbnPods[1].IP))
				err := utils.PingFromPod(ctx, hostedConfig, hostedClientset,
					cfg.DPFNamespace, hbnPods[0].Name, "doca-hbn",
					hbnPods[1].IP, cfg.PingCount, 1490)
				Expect(err).NotTo(HaveOccurred())

				By(fmt.Sprintf("Pinging from HBN %s to HBN %s (IP=%s) MTU 1490", hbnPods[1].Name, hbnPods[0].Name, hbnPods[0].IP))
				err = utils.PingFromPod(ctx, hostedConfig, hostedClientset,
					cfg.DPFNamespace, hbnPods[1].Name, "doca-hbn",
					hbnPods[0].IP, cfg.PingCount, 1490)
				Expect(err).NotTo(HaveOccurred())
			})

			It("should ping between HBN pods cross-node (MTU 8970 jumbo)", Label("hbn"), func() {
				By(fmt.Sprintf("Pinging from HBN %s to HBN %s (IP=%s) MTU 8970", hbnPods[0].Name, hbnPods[1].Name, hbnPods[1].IP))
				err := utils.PingFromPod(ctx, hostedConfig, hostedClientset,
					cfg.DPFNamespace, hbnPods[0].Name, "doca-hbn",
					hbnPods[1].IP, cfg.PingCount, 8970)
				Expect(err).NotTo(HaveOccurred())

				By(fmt.Sprintf("Pinging from HBN %s to HBN %s (IP=%s) MTU 8970", hbnPods[1].Name, hbnPods[0].Name, hbnPods[0].IP))
				err = utils.PingFromPod(ctx, hostedConfig, hostedClientset,
					cfg.DPFNamespace, hbnPods[1].Name, "doca-hbn",
					hbnPods[0].IP, cfg.PingCount, 8970)
				Expect(err).NotTo(HaveOccurred())
			})
		})
	})
})

func checkClusterOperatorsHealthy(c client.Client, clusterName string) {
	coList := &unstructured.UnstructuredList{}
	coList.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "config.openshift.io",
		Version: "v1",
		Kind:    "ClusterOperatorList",
	})

	err := c.List(ctx, coList)
	Expect(err).NotTo(HaveOccurred(), "failed to list ClusterOperators on %s cluster", clusterName)

	var degraded, progressing []string
	for _, co := range coList.Items {
		name := co.GetName()
		conditions, found, err := unstructured.NestedSlice(co.Object, "status", "conditions")
		Expect(err).NotTo(HaveOccurred())
		if !found {
			continue
		}
		for _, c := range conditions {
			cond, ok := c.(map[string]interface{})
			if !ok {
				continue
			}
			condType, _, _ := unstructured.NestedString(cond, "type")
			condStatus, _, _ := unstructured.NestedString(cond, "status")
			if condType == "Degraded" && condStatus == "True" {
				msg, _, _ := unstructured.NestedString(cond, "message")
				degraded = append(degraded, fmt.Sprintf("%s: %s", name, msg))
			}
			if condType == "Progressing" && condStatus == "True" {
				msg, _, _ := unstructured.NestedString(cond, "message")
				progressing = append(progressing, fmt.Sprintf("%s: %s", name, msg))
			}
		}
	}

	if len(degraded) > 0 {
		GinkgoWriter.Printf("Degraded operators on %s cluster:\n", clusterName)
		for _, d := range degraded {
			GinkgoWriter.Printf("  - %s\n", d)
		}
	}
	if len(progressing) > 0 {
		GinkgoWriter.Printf("Progressing operators on %s cluster:\n", clusterName)
		for _, p := range progressing {
			GinkgoWriter.Printf("  - %s\n", p)
		}
	}

	Expect(degraded).To(BeEmpty(), "found degraded cluster operators on %s cluster", clusterName)
	Expect(progressing).To(BeEmpty(), "found progressing cluster operators on %s cluster", clusterName)
}
