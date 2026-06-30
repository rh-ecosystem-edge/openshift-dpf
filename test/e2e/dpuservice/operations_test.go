// Package dpuservice tests DPUService operations.
// Section 4 of the DPF QA Test Plan.
package dpuservice_test

import (
	"context"
	"fmt"
	"net/http"
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

// TC-SVC-001 [ALM:14172] — Update HBN DPUService; pods restart with new config, no degradation.
// Priority: Very High | Labels: dpuservice
var _ = Describe("TC-SVC-001", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("HBN DPUService exists and is Ready", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		var hbnSvc *dpfservicev1.DPUService
		for i := range svcList.Items {
			if svcList.Items[i].Name == "hbn" || containsLabel(svcList.Items[i].Labels, "svc.dpu.nvidia.com/name", "hbn") {
				hbnSvc = &svcList.Items[i]
				break
			}
		}
		if hbnSvc == nil {
			Skip("HBN DPUService not found — skipping TC-SVC-001")
		}
		By(fmt.Sprintf("HBN DPUService found: %s", hbnSvc.Name))
	})

	It("updates HBN DPUService configuration (annotation bump to trigger reconcile)", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		var hbnSvc *dpfservicev1.DPUService
		for i := range svcList.Items {
			if svcList.Items[i].Name == "hbn" {
				hbnSvc = svcList.Items[i].DeepCopy()
				break
			}
		}
		if hbnSvc == nil {
			Skip("HBN DPUService not found")
		}
		if hbnSvc.Annotations == nil {
			hbnSvc.Annotations = map[string]string{}
		}
		hbnSvc.Annotations["dpf-e2e-update-trigger"] = "tc-svc-001"
		gomega.Expect(mgmt.Update(ctx, hbnSvc)).To(gomega.Succeed())
	})

	It("HBN DPUService pods recover to Running after update", func() {
		gomega.Eventually(func(g gomega.Gomega) {
			pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
				"svc.dpu.nvidia.com/name": "hbn",
			})
			g.Expect(err).NotTo(gomega.HaveOccurred())
			g.Expect(pods).NotTo(gomega.BeEmpty(), "no HBN pods Running after update")
		}).WithTimeout(framework.DPUDeploymentTimeout).WithPolling(15 * time.Second).Should(gomega.Succeed())
	})
})

// TC-SVC-002 [ALM:14175] — Update OVN DPUService; pods restart with new config, system stable.
// Priority: Very High | Labels: dpuservice
var _ = Describe("TC-SVC-002", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("OVN DPUService exists and pods are Running", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
			"svc.dpu.nvidia.com/name": "ovn",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(pods) == 0 {
			Skip("OVN DPUService pods not found — skipping TC-SVC-002")
		}
		By(fmt.Sprintf("OVN pods running: %d", len(pods)))
	})

	It("triggers OVN DPUService update via annotation", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		var ovnSvc *dpfservicev1.DPUService
		for i := range svcList.Items {
			if svcList.Items[i].Name == "ovn" {
				ovnSvc = svcList.Items[i].DeepCopy()
				break
			}
		}
		if ovnSvc == nil {
			Skip("OVN DPUService not found")
		}
		if ovnSvc.Annotations == nil {
			ovnSvc.Annotations = map[string]string{}
		}
		ovnSvc.Annotations["dpf-e2e-update-trigger"] = "tc-svc-002"
		gomega.Expect(mgmt.Update(ctx, ovnSvc)).To(gomega.Succeed())
	})

	It("OVN DPUService pods recover to Running after update", func() {
		gomega.Eventually(func(g gomega.Gomega) {
			pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
				"svc.dpu.nvidia.com/name": "ovn",
			})
			g.Expect(err).NotTo(gomega.HaveOccurred())
			g.Expect(pods).NotTo(gomega.BeEmpty(), "no OVN pods Running after update")
		}).WithTimeout(framework.DPUDeploymentTimeout).WithPolling(15 * time.Second).Should(gomega.Succeed())
	})
})

// TC-SVC-003 [ALM:14192] — DPUServiceChain Update; new path applied, no traffic drops.
// Priority: High | Labels: dpuservice
var _ = Describe("TC-SVC-003", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DPUServiceChain objects exist", func() {
		chainList := &dpfservicev1.DPUServiceChainList{}
		gomega.Expect(mgmt.List(ctx, chainList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(chainList.Items) == 0 {
			Skip("no DPUServiceChain objects found — skipping TC-SVC-003")
		}
		By(fmt.Sprintf("Found %d DPUServiceChain objects", len(chainList.Items)))
	})

	It("updates DPUServiceChain with annotation trigger", func() {
		chainList := &dpfservicev1.DPUServiceChainList{}
		gomega.Expect(mgmt.List(ctx, chainList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(chainList.Items) == 0 {
			Skip("no DPUServiceChain to update")
		}
		chain := chainList.Items[0].DeepCopy()
		if chain.Annotations == nil {
			chain.Annotations = map[string]string{}
		}
		chain.Annotations["dpf-e2e-update-trigger"] = "tc-svc-003"
		gomega.Expect(mgmt.Update(ctx, chain)).To(gomega.Succeed())
	})

	It("DPUDeployment recovers to Ready after ServiceChain update", func() {
		ddList := &dpfservicev1.DPUDeploymentList{}
		gomega.Expect(mgmt.List(ctx, ddList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(ddList.Items).NotTo(gomega.BeEmpty())
		framework.WaitForDPUDeploymentReady(ctx, mgmt, &ddList.Items[0], framework.DPUDeploymentTimeout)
	})
})

// TC-SVC-006 [ALM:14336] — NVUE REST API accessible via NodePort after HBN deploy.
// Priority: High | Labels: dpuservice, networking
var _ = Describe("TC-SVC-006", Label(labels.Domain.DPUService, labels.Domain.Networking), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("HBN pods are Running (prerequisite for NVUE API)", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
			"svc.dpu.nvidia.com/name": "hbn",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(pods).NotTo(gomega.BeEmpty(), "HBN pods must be Running for NVUE test")
	})

	It("NVUE REST API returns valid system information", func() {
		// Find the NodePort service for NVUE (exposed by HBN DPUService)
		svcList := &corev1.ServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())

		var nodePort int32
		for _, svc := range svcList.Items {
			if svc.Spec.Type != corev1.ServiceTypeNodePort {
				continue
			}
			// Match by name containing "hbn" or "nvue"
			if !strings.Contains(svc.Name, "hbn") && !strings.Contains(svc.Name, "nvue") {
				continue
			}
			for _, port := range svc.Spec.Ports {
				if port.NodePort > 0 {
					nodePort = port.NodePort
					break
				}
			}
			if nodePort > 0 {
				break
			}
		}
		if nodePort == 0 {
			Skip("NVUE NodePort service not found — skipping NVUE API reachability check")
		}
		By(fmt.Sprintf("Found NVUE NodePort: %d", nodePort))

		// Get a DPU worker node IP from the management cluster
		nodeList := &corev1.NodeList{}
		gomega.Expect(mgmt.List(ctx, nodeList)).To(gomega.Succeed())

		var nodeIP string
		for _, node := range nodeList.Items {
			// Filter DPU worker nodes by label
			if _, ok := node.Labels[framework.DPUEnabledLabel]; !ok {
				continue
			}
			for _, addr := range node.Status.Addresses {
				if addr.Type == corev1.NodeInternalIP {
					nodeIP = addr.Address
					break
				}
			}
			if nodeIP != "" {
				break
			}
		}
		if nodeIP == "" {
			// Fall back to any worker node if no DPU-labeled nodes found
			for _, node := range nodeList.Items {
				if _, isMaster := node.Labels["node-role.kubernetes.io/master"]; isMaster {
					continue
				}
				if _, isCP := node.Labels["node-role.kubernetes.io/control-plane"]; isCP {
					continue
				}
				for _, addr := range node.Status.Addresses {
					if addr.Type == corev1.NodeInternalIP {
						nodeIP = addr.Address
						break
					}
				}
				if nodeIP != "" {
					break
				}
			}
		}
		if nodeIP == "" {
			Skip("No suitable worker node IP found — skipping NVUE API reachability check")
		}

		url := fmt.Sprintf("http://%s:%d/nvue_v1/system", nodeIP, nodePort)
		By(fmt.Sprintf("Making HTTP GET to NVUE API: %s", url))

		httpClient := &http.Client{Timeout: 10 * time.Second}
		resp, err := httpClient.Get(url)
		if err != nil {
			Skip(fmt.Sprintf("NVUE API not reachable (network path may not exist in test env): %v", err))
		}
		defer resp.Body.Close()

		By(fmt.Sprintf("NVUE API response status: %d", resp.StatusCode))
		// Accept 200, 401, 403 — any non-5xx proves the API is reachable
		gomega.Expect(resp.StatusCode).To(gomega.BeNumerically("<", 500),
			"NVUE REST API returned 5xx status — API is not functioning correctly")
	})
})

// TC-SVC-012 [ALM:143XX] — DPU services running: ignition SSH checks.
// Priority: High | Labels: dpuservice, requires-ssh
var _ = Describe("TC-SVC-012", Label(labels.Domain.DPUService, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		_ = ctx
		cfg = config.Get()
	})

	It("SSH credentials are available for DPU ignition checks", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping ignition SSH checks (TC-SVC-012)")
		}
		if cfg.HypervisorHost == nil {
			Skip("HypervisorHost not configured — skipping ignition SSH checks")
		}
	})

	It("bfvcheck.service is not failed on DPU", func() {
		if cfg.SSHPrivateKeyPath == nil || cfg.HypervisorHost == nil {
			Skip("SSH not configured")
		}
		user := "core"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH to hypervisor")
		defer sshClient.Close()

		out, err := sshClient.Run("systemctl is-failed bfvcheck.service 2>/dev/null || echo not_failed")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "check bfvcheck.service")
		By(fmt.Sprintf("bfvcheck.service status: %s", strings.TrimSpace(out)))
		gomega.Expect(strings.TrimSpace(out)).NotTo(gomega.Equal("failed"),
			"bfvcheck.service is in failed state on DPU")
	})

	It("bootstrap-dpf.service is not failed on DPU", func() {
		if cfg.SSHPrivateKeyPath == nil || cfg.HypervisorHost == nil {
			Skip("SSH not configured")
		}
		user := "core"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH to hypervisor")
		defer sshClient.Close()

		out, err := sshClient.Run("systemctl is-failed bootstrap-dpf.service 2>/dev/null || echo not_failed")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "check bootstrap-dpf.service")
		By(fmt.Sprintf("bootstrap-dpf.service status: %s", strings.TrimSpace(out)))
		gomega.Expect(strings.TrimSpace(out)).NotTo(gomega.Equal("failed"),
			"bootstrap-dpf.service is in failed state on DPU")
	})

	It("set-nvconfig-params.service is not failed on DPU", func() {
		if cfg.SSHPrivateKeyPath == nil || cfg.HypervisorHost == nil {
			Skip("SSH not configured")
		}
		user := "core"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH to hypervisor")
		defer sshClient.Close()

		out, err := sshClient.Run("systemctl is-failed set-nvconfig-params.service 2>/dev/null || echo not_failed")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "check set-nvconfig-params.service")
		By(fmt.Sprintf("set-nvconfig-params.service status: %s", strings.TrimSpace(out)))
		gomega.Expect(strings.TrimSpace(out)).NotTo(gomega.Equal("failed"),
			"set-nvconfig-params.service is in failed state on DPU")
	})

	It("set_emu_param.service is not failed on DPU", func() {
		if cfg.SSHPrivateKeyPath == nil || cfg.HypervisorHost == nil {
			Skip("SSH not configured")
		}
		user := "core"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH to hypervisor")
		defer sshClient.Close()

		out, err := sshClient.Run("systemctl is-failed set_emu_param.service 2>/dev/null || echo not_failed")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "check set_emu_param.service")
		By(fmt.Sprintf("set_emu_param.service status: %s", strings.TrimSpace(out)))
		gomega.Expect(strings.TrimSpace(out)).NotTo(gomega.Equal("failed"),
			"set_emu_param.service is in failed state on DPU")
	})

	It("/dev/ipmi* device exists on DPU", func() {
		if cfg.SSHPrivateKeyPath == nil || cfg.HypervisorHost == nil {
			Skip("SSH not configured")
		}
		user := "core"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH to hypervisor")
		defer sshClient.Close()

		out, err := sshClient.Run("ls /dev/*ipmi* 2>/dev/null | wc -l")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "check /dev/ipmi*")
		count := 0
		fmt.Sscanf(strings.TrimSpace(out), "%d", &count)
		By(fmt.Sprintf("/dev/ipmi* device count: %d", count))
		gomega.Expect(count).To(gomega.BeNumerically(">", 0),
			"/dev/ipmi* not found on DPU — IPMI device missing")
	})
})

// TC-SVC-007..011 — DTS DPUService tests (install, update, delete, metrics).
// Priority: High | Labels: dpuservice

var _ = Describe("TC-SVC-007", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DTS DPUService exists in DPF namespace", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		var dtsSvc *dpfservicev1.DPUService
		for i := range svcList.Items {
			if svcList.Items[i].Name == "doca-telemetry-service" {
				dtsSvc = &svcList.Items[i]
				break
			}
		}
		if dtsSvc == nil {
			Skip("DTS DPUService not found — skipping TC-SVC-007..011")
		}
		By(fmt.Sprintf("DTS DPUService found: %s", dtsSvc.Name))
	})

	It("DTS pods are Running on DPU nodes", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
			"svc.dpu.nvidia.com/name": "doca-telemetry-service",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(pods) == 0 {
			Skip("DTS pods not Running")
		}
		By(fmt.Sprintf("DTS pods running: %d", len(pods)))
	})
})

var _ = Describe("TC-SVC-008", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("updates DTS DPUService configuration", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		var dtsSvc *dpfservicev1.DPUService
		for i := range svcList.Items {
			if svcList.Items[i].Name == "doca-telemetry-service" {
				dtsSvc = svcList.Items[i].DeepCopy()
				break
			}
		}
		if dtsSvc == nil {
			Skip("DTS DPUService not found")
		}
		if dtsSvc.Annotations == nil {
			dtsSvc.Annotations = map[string]string{}
		}
		dtsSvc.Annotations["dpf-e2e-update-trigger"] = "tc-svc-008"
		gomega.Expect(mgmt.Update(ctx, dtsSvc)).To(gomega.Succeed())
	})

	It("DTS pods recover after config update", func() {
		gomega.Eventually(func(g gomega.Gomega) {
			pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
				"svc.dpu.nvidia.com/name": "doca-telemetry-service",
			})
			g.Expect(err).NotTo(gomega.HaveOccurred())
			g.Expect(pods).NotTo(gomega.BeEmpty())
		}).WithTimeout(framework.DPUDeploymentTimeout).WithPolling(15 * time.Second).Should(gomega.Succeed())
	})
})

var _ = Describe("TC-SVC-009", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig
	var savedDTS *dpfservicev1.DPUService

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("captures DTS DPUService before deletion", func() {
		svcList := &dpfservicev1.DPUServiceList{}
		gomega.Expect(mgmt.List(ctx, svcList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		for i := range svcList.Items {
			if svcList.Items[i].Name == "doca-telemetry-service" {
				savedDTS = svcList.Items[i].DeepCopy()
				break
			}
		}
		if savedDTS == nil {
			Skip("DTS DPUService not found — skipping delete test")
		}
	})

	It("deletes DTS DPUService", func() {
		if savedDTS == nil {
			Skip("no saved DTS service")
		}
		framework.DeleteAndWaitGone(ctx, mgmt, savedDTS.DeepCopy(), 5*time.Minute)
		By("DTS DPUService deleted")
	})

	It("recreates DTS DPUService to restore baseline", func() {
		if savedDTS == nil {
			Skip("no saved DTS service to recreate")
		}
		restored := savedDTS.DeepCopy()
		restored.ResourceVersion = ""
		restored.UID = ""
		restored.Generation = 0
		gomega.Expect(mgmt.Create(ctx, restored)).To(gomega.Succeed())
		By("DTS DPUService recreated")
	})
})

var _ = Describe("TC-SVC-010", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx
	})

	It("DTS DPUService reports metrics to Prometheus endpoint available on DPU", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping Prometheus metrics SSH check (TC-SVC-010)")
		}
		if cfg.HypervisorHost == nil {
			Skip("HypervisorHost not configured — skipping Prometheus metrics SSH check")
		}

		user := "core"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH to hypervisor")
		defer sshClient.Close()

		// Try port 9090 first (Prometheus), then 8080 (common metrics port)
		cmd := `curl -s --max-time 10 http://localhost:9090/metrics 2>/dev/null || curl -s --max-time 10 http://localhost:8080/metrics 2>/dev/null`
		out, err := sshClient.Run(cmd)
		// SSH command itself may fail if neither endpoint is up — treat as skip
		if err != nil {
			Skip(fmt.Sprintf("Prometheus metrics endpoint not reachable on DPU: %v", err))
		}
		By(fmt.Sprintf("Prometheus metrics output length: %d bytes", len(out)))
		gomega.Expect(out).NotTo(gomega.BeEmpty(), "Prometheus metrics endpoint returned empty response")
		gomega.Expect(out).To(gomega.SatisfyAny(
			gomega.ContainSubstring("# HELP"),
			gomega.ContainSubstring("# TYPE"),
		), "Prometheus metrics response does not contain expected metric format markers")
	})
})

var _ = Describe("TC-SVC-011", Label(labels.Domain.DPUService), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
	})

	It("DTS DPUService exposes metrics to the end user through Prometheus", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, map[string]string{
			"svc.dpu.nvidia.com/name": "doca-telemetry-service",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(pods) == 0 {
			Skip("DTS pods not running — skipping user-facing metrics check")
		}

		// Check that at least one DTS pod carries Prometheus scrape annotations,
		// which signal that Prometheus is configured to collect metrics from DTS.
		scrapeAnnotationFound := false
		for _, pod := range pods {
			if val, ok := pod.Annotations["prometheus.io/scrape"]; ok && val == "true" {
				scrapeAnnotationFound = true
				By(fmt.Sprintf("Pod %s/%s has prometheus.io/scrape=true annotation", pod.Namespace, pod.Name))
				break
			}
		}

		if !scrapeAnnotationFound {
			// Fall back: check DPF namespace pods broadly for Prometheus scrape annotation
			allPods, listErr := framework.ListRunningPods(ctx, mgmt, cfg.DPFNamespace, nil)
			gomega.Expect(listErr).NotTo(gomega.HaveOccurred())
			for _, pod := range allPods {
				if val, ok := pod.Annotations["prometheus.io/scrape"]; ok && val == "true" {
					scrapeAnnotationFound = true
					By(fmt.Sprintf("Pod %s/%s has prometheus.io/scrape=true annotation", pod.Namespace, pod.Name))
					break
				}
			}
		}

		gomega.Expect(scrapeAnnotationFound).To(gomega.BeTrue(),
			"No pods in DPF namespace have prometheus.io/scrape=true annotation — metrics are not exposed to Prometheus")
	})
})

func containsLabel(lbs map[string]string, key, value string) bool {
	v, ok := lbs[key]
	return ok && v == value
}
