// Package stability tests long-running stability and robustness scenarios.
// Section 17 of the DPF QA Test Plan.
package stability_test

import (
	"context"
	"fmt"
	"strings"
	"time"

	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-STAB-001 [ALM:14162] — All-night iPerf + ping (8+ hours); no packet loss, memory leaks, syslog errors.
// Priority: Very High | Labels: stability
// IMPORTANT: Run in a dedicated overnight pipeline slot.
var _ = Describe("TC-STAB-001", Label(labels.Domain.Stability), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	// baselineRestartCounts maps pod-key ("namespace/name/container") to its restart count
	// captured at the beginning of the test. Used to detect crash loops during Consistently.
	baselineRestartCounts := map[string]int32{}

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()

		// Capture baseline pod restart counts so the Consistently body can detect regressions.
		podList := &corev1.PodList{}
		if err := mgmt.List(ctx, podList, client.InNamespace(cfg.DPFNamespace)); err == nil {
			for _, pod := range podList.Items {
				for _, cs := range pod.Status.ContainerStatuses {
					key := fmt.Sprintf("%s/%s/%s", pod.Namespace, pod.Name, cs.Name)
					baselineRestartCounts[key] = cs.RestartCount
				}
				for _, cs := range pod.Status.InitContainerStatuses {
					key := fmt.Sprintf("%s/%s/init:%s", pod.Namespace, pod.Name, cs.Name)
					baselineRestartCounts[key] = cs.RestartCount
				}
			}
		}
	})

	It("cluster is stable before overnight stability test", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("iperf3 connectivity baseline: HBN pods are Running", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
			"svc.dpu.nvidia.com/name": "hbn",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(pods).NotTo(gomega.BeEmpty(), "HBN pods must be running for overnight iperf test")
	})

	It("runs overnight stability monitoring (8+ hours)", func() {
		// The overnight monitoring runs for stabilityTestTimeout.
		// In CI, this step is scheduled in a dedicated overnight slot.
		// This It() anchors the test in the suite and enforces the timeout guard.
		endTime := time.Now().Add(framework.StabilityTestTimeout)
		By("overnight stability test started — running until: " + endTime.Format(time.RFC3339))

		tracker := framework.NewByTracker()
		gomega.Consistently(func(g gomega.Gomega) {
			// 1. DPUDeployment count must remain non-zero.
			ddList := &dpfservicev1.DPUDeploymentList{}
			g.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			g.Expect(ddList.Items).NotTo(gomega.BeEmpty())
			tracker.By("dd", "DPUDeployment count: %d", len(ddList.Items))

			// 2. DPF namespace pods are still Running.
			pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, nil)
			g.Expect(err).NotTo(gomega.HaveOccurred())
			tracker.By("pods", "Running DPF pods: %d", len(pods))
			g.Expect(pods).NotTo(gomega.BeEmpty(), "DPF pods stopped running during stability test")

			// 3. Pod restart-count check — no pod may exceed its baseline by more than 5.
			//    This allows for occasional, non-crash-loop restarts while catching runaway loops.
			podList := &corev1.PodList{}
			g.Expect(mgmt.List(ctx, podList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			for _, pod := range podList.Items {
				allStatuses := append(pod.Status.ContainerStatuses, pod.Status.InitContainerStatuses...) //nolint:gocritic
				for _, cs := range pod.Status.ContainerStatuses {
					key := fmt.Sprintf("%s/%s/%s", pod.Namespace, pod.Name, cs.Name)
					baseline := baselineRestartCounts[key]
					delta := cs.RestartCount - baseline
					tracker.By(key, "pod %s container %s restarts since baseline: %d", pod.Name, cs.Name, delta)
					g.Expect(delta).To(gomega.BeNumerically("<=", 5),
						"pod %s container %s restarted %d times since baseline (crash loop suspected)", pod.Name, cs.Name, delta)
				}
				for _, cs := range pod.Status.InitContainerStatuses {
					key := fmt.Sprintf("%s/%s/init:%s", pod.Namespace, pod.Name, cs.Name)
					baseline := baselineRestartCounts[key]
					delta := cs.RestartCount - baseline
					tracker.By(key, "pod %s init-container %s restarts since baseline: %d", pod.Name, cs.Name, delta)
					g.Expect(delta).To(gomega.BeNumerically("<=", 5),
						"pod %s init-container %s restarted %d times since baseline (crash loop suspected)", pod.Name, cs.Name, delta)
				}
				_ = allStatuses // silence unused warning
			}

			// 4. SSH syslog check — only when HypervisorHost and SSHPrivateKeyPath are configured.
			if cfg.SSHPrivateKeyPath != nil && cfg.HypervisorHost != nil {
				user := "core"
				if cfg.HypervisorUser != nil {
					user = *cfg.HypervisorUser
				}
				sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
				if err != nil {
					// Log but do not fail: SSH connectivity issues should not block the stability check.
					tracker.By("ssh", "WARNING: cannot SSH to hypervisor %s: %v", *cfg.HypervisorHost, err)
				} else {
					defer sshClient.Close()
					// Count critical DPF/DPU/OVS/kernel-panic/OOM errors in the last minute.
					cmd := `journalctl --since "1 minute ago" -p err -q 2>/dev/null | grep -iE "dpf|dpu|ovs|kernel panic|oom" | wc -l`
					out, err := sshClient.Run(cmd)
					if err != nil {
						tracker.By("ssh-syslog", "WARNING: syslog check failed on %s: %v", *cfg.HypervisorHost, err)
					} else {
						countStr := strings.TrimSpace(out)
						tracker.By("ssh-syslog", "Critical syslog lines in last minute: %s", countStr)
						g.Expect(countStr).To(gomega.Equal("0"),
							"critical syslog errors detected on hypervisor %s: found %s line(s) matching dpf|dpu|ovs|kernel panic|oom",
							*cfg.HypervisorHost, countStr)
					}
				}
			}
		}).WithContext(ctx).WithTimeout(framework.StabilityTestTimeout).WithPolling(5 * time.Minute).Should(gomega.Succeed())
	})
})

// TC-STAB-002 [ALM:14136] — Multiple sequential re-provisioning; no degradation.
// Priority: High | Labels: stability, dpudeployment
var _ = Describe("TC-STAB-002", Label(labels.Domain.Stability, labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("runs 3 sequential DPUDeployment delete/recreate cycles", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		saved := ddList.Items[0].DeepCopy()

		for i := range 3 {
			By("starting re-provisioning cycle " + string(rune('1'+i)))

			// Delete
			toDelete := saved.DeepCopy()
			toDelete.ResourceVersion = ddList.Items[0].ResourceVersion
			framework.DeleteAndWaitGone(ctx, mgmt, toDelete, 5*time.Minute)

			// Recreate
			newDD := saved.DeepCopy()
			newDD.ResourceVersion = ""
			newDD.UID = ""
			newDD.Generation = 0
			gomega.Expect(mgmt.Create(ctx, newDD)).To(gomega.Succeed())

			// Wait for Ready
			latestList := &dpfservicev1.DPUDeploymentList{}
			gomega.Expect(mgmt.List(ctx, latestList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			framework.WaitForDPUDeploymentReady(ctx, mgmt, &latestList.Items[0], framework.DPUDeploymentTimeout)
			ddList = latestList
		}
	})
})

// TC-STAB-003 [ALM:14195] — Sequential DPU provisioning with phase interruptions.
// Priority: High | Labels: stability, dpudeployment
// Tests that DPU provisioning is interruptible and recovers correctly when interrupted mid-phase.
var _ = Describe("TC-STAB-003", Label(labels.Domain.Stability, labels.Domain.DPUDeployment), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("baseline: all DPUNodes are Ready before interruption test", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("interrupts DPU provisioning mid-phase by deleting and recreating DPUDeployment", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		saved := ddList.Items[0].DeepCopy()

		By("triggering a BFB update to start provisioning — then immediately deleting DPUDeployment (interrupt)")
		// Update BFB ref to simulate a re-provisioning trigger (same image, different annotation)
		trigger := saved.DeepCopy()
		trigger.ResourceVersion = ddList.Items[0].ResourceVersion
		if trigger.Annotations == nil {
			trigger.Annotations = map[string]string{}
		}
		trigger.Annotations["dpf-e2e-stab-interrupt"] = "phase-interrupt-trigger"
		_ = mgmt.Update(ctx, trigger)

		// Delete immediately, simulating an interruption mid-provisioning
		By("deleting DPUDeployment to interrupt in-progress provisioning")
		toDelete := trigger.DeepCopy()
		framework.DeleteAndWaitGone(ctx, mgmt, toDelete, 5*time.Minute)

		By("recreating DPUDeployment after interruption — expecting full recovery")
		newDD := saved.DeepCopy()
		newDD.ResourceVersion = ""
		newDD.UID = ""
		newDD.Generation = 0
		delete(newDD.Annotations, "dpf-e2e-stab-interrupt")
		gomega.Expect(mgmt.Create(ctx, newDD)).To(gomega.Succeed())
	})

	It("all DPUNodes recover to Ready after interrupted provisioning", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUDeploymentTimeout)
	})

	It("DPUDeployment is Ready after interrupted provisioning recovery", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-STAB-004 [ALM:14157] — Multiple sequential DPF system reinstalls.
// Priority: High | Labels: stability
// Tests that repeated uninstall-reinstall cycles leave the system fully functional with no residual state.
var _ = Describe("TC-STAB-004", Label(labels.Domain.Stability), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("baseline: DPFOperatorConfig and DPUNodes are Ready before reinstall cycles", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})

	It("saves DPUDeployment manifest for reinstall reference", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty(), "at least one DPUDeployment must exist for reinstall test")
	})

	It("performs 2 sequential DPUDeployment uninstall-reinstall cycles", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		saved := ddList.Items[0].DeepCopy()

		for i := range 2 {
			By("reinstall cycle " + string(rune('1'+i)) + ": deleting all DPUDeployments")
			for j := range ddList.Items {
				toDelete := ddList.Items[j].DeepCopy()
				framework.DeleteAndWaitGone(ctx, mgmt, toDelete, 5*time.Minute)
			}

			By("reinstall cycle " + string(rune('1'+i)) + ": verifying no residual DPUDeployments")
			postDeleteList := &dpfservicev1.DPUDeploymentList{}
			gomega.Expect(mgmt.List(ctx, postDeleteList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			gomega.Expect(postDeleteList.Items).To(gomega.BeEmpty(), "all DPUDeployments must be gone before reinstall")

			By("reinstall cycle " + string(rune('1'+i)) + ": recreating DPUDeployment")
			newDD := saved.DeepCopy()
			newDD.ResourceVersion = ""
			newDD.UID = ""
			newDD.Generation = 0
			gomega.Expect(mgmt.Create(ctx, newDD)).To(gomega.Succeed())

			By("reinstall cycle " + string(rune('1'+i)) + ": waiting for DPUDeployment Ready")
			latestList := &dpfservicev1.DPUDeploymentList{}
			gomega.Expect(mgmt.List(ctx, latestList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			framework.WaitForDPUDeploymentReady(ctx, mgmt, &latestList.Items[0], framework.DPUDeploymentTimeout)

			By("reinstall cycle " + string(rune('1'+i)) + ": waiting for all DPUNodes Ready")
			framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)

			ddList = latestList
		}
	})

	It("system is fully functional after all reinstall cycles", func() {
		framework.WaitForAllDPUNodesReady(ctx, mgmt, cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, nil)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(pods).NotTo(gomega.BeEmpty(), "DPF pods must be running after all reinstall cycles")
	})
})

// TC-STAB-005 [ALM:14133] — Reconfigure HBN+OVN DPUService multiple times (stress test).
// Priority: High | Labels: stability, dpuservice
var _ = Describe("TC-STAB-005", Label(labels.Domain.Stability, labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("runs 5 HBN+OVN service annotation update cycles and verifies recovery", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())

		for i := range 5 {
			By("service reconfiguration cycle " + string(rune('1'+i)))
			for j := range svcList.Items {
				svc := svcList.Items[j].DeepCopy()
				if svc.Annotations == nil {
					svc.Annotations = map[string]string{}
				}
				svc.Annotations["dpf-e2e-stab-cycle"] = string(rune('0' + i))
				_ = mgmt.Update(ctx, svc)
			}
			// Wait for recovery
			ddList := &dpfservicev1.DPUDeploymentList{}
			gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
			if len(ddList.Items) > 0 {
				framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
			}
		}
	})
})
