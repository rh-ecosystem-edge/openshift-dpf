package e2e

import (
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var _ = Describe("Cluster Health Verification", Label("cluster-health"), func() {
	Describe("Cluster Operators", func() {
		It("all cluster operators are healthy on the management cluster", func() {
			checkClusterOperatorsHealthy(mgmtClient, "management")
		})

		It("all cluster operators are healthy on the hosted cluster", func() {
			checkClusterOperatorsHealthy(hostedClient, "hosted")
		})
	})

	Describe("DPU Worker Pods", func() {
		It("all pods on DPU worker nodes are Running and not CrashLooping", func() {
			Expect(dpuHostWorkers).NotTo(BeEmpty(), "no DPU-enabled host worker nodes discovered")

			for _, node := range dpuHostWorkers {
				By(fmt.Sprintf("Checking pods on DPU worker node %s", node.Name))

				podList := &corev1.PodList{}
				Expect(mgmtClient.List(ctx, podList,
					client.MatchingFields{"spec.nodeName": node.Name},
				)).To(Succeed(), "failed to list pods on node %s", node.Name)

				var crashLooping []string
				var notRunning []string

				for _, pod := range podList.Items {
					if pod.Status.Phase == corev1.PodSucceeded || pod.Status.Phase == corev1.PodFailed {
						if pod.Status.Phase == corev1.PodFailed {
							notRunning = append(notRunning, fmt.Sprintf("%s/%s (phase=%s)",
								pod.Namespace, pod.Name, pod.Status.Phase))
						}
						continue
					}

					if pod.Status.Phase != corev1.PodRunning {
						notRunning = append(notRunning, fmt.Sprintf("%s/%s (phase=%s)",
							pod.Namespace, pod.Name, pod.Status.Phase))
						continue
					}

					for _, cs := range pod.Status.ContainerStatuses {
						if cs.RestartCount > 5 && cs.State.Waiting != nil &&
							cs.State.Waiting.Reason == "CrashLoopBackOff" {
							crashLooping = append(crashLooping, fmt.Sprintf(
								"%s/%s container=%s restarts=%d",
								pod.Namespace, pod.Name, cs.Name, cs.RestartCount))
						}
					}
				}

				if len(notRunning) > 0 {
					GinkgoWriter.Printf("Non-running pods on node %s:\n", node.Name)
					for _, p := range notRunning {
						GinkgoWriter.Printf("  - %s\n", p)
					}
				}
				if len(crashLooping) > 0 {
					GinkgoWriter.Printf("CrashLooping pods on node %s:\n", node.Name)
					for _, p := range crashLooping {
						GinkgoWriter.Printf("  - %s\n", p)
					}
				}

				Expect(crashLooping).To(BeEmpty(),
					"found CrashLooping pods on DPU worker node %s", node.Name)
				Expect(notRunning).To(BeEmpty(),
					"found non-running pods on DPU worker node %s", node.Name)

				GinkgoWriter.Printf("Node %s: all %d pods healthy\n", node.Name, len(podList.Items))
			}
		})
	})
})
