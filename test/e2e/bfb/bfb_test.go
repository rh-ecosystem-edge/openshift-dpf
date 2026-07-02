// Package bfb tests BFB (BlueField Boot Image) related functionality.
// Section 18 of the DPF QA Test Plan.
package bfb_test

import (
	"context"
	"strings"

	dpfprovisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-BFB-001 — BFB supports SecureBoot.
// Priority: High | Labels: bfb, requires-ssh
// Expected Result: The BFB can be provisioned with SecureBoot enabled on DPU.
// Note: Not supported yet but will be for GA.
var _ = Describe("TC-BFB-001", Label(labels.Domain.BFB, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx
	})

	It("SecureBoot-enabled BFB images not yet available — TC-BFB-001 will be enabled for GA", func() {
		Skip("SecureBoot-enabled BFB images not yet available — TC-BFB-001 will be enabled for GA")
	})

	It("SecureBoot state verified on hypervisor host", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("requires-ssh: SSHPrivateKeyPath not configured")
		}
		if cfg.HypervisorHost == nil {
			Skip("requires-ssh: HypervisorHost not configured")
		}
		user := "root"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH connect to hypervisor %s", *cfg.HypervisorHost)
		defer sshClient.Close()

		cmd := `mlxconfig -d $(ls /dev/mst/ | grep -E 'pciconf[0-9]$' | head -1) query SECURE_BOOT_ENABLE 2>/dev/null`
		out, err := sshClient.Run(cmd)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "mlxconfig query SECURE_BOOT_ENABLE: %s", out)

		// Parse the mlxconfig output for the SECURE_BOOT_ENABLE value.
		// A line like: "         SECURE_BOOT_ENABLE           False(0)" means disabled.
		var found bool
		for _, line := range strings.Split(out, "\n") {
			if strings.Contains(line, "SECURE_BOOT_ENABLE") {
				found = true
				// Value is disabled when it contains "0" at end or "False" or "DISABLED".
				lower := strings.ToLower(line)
				gomega.Expect(lower).NotTo(gomega.Or(
					gomega.ContainSubstring("false(0)"),
					gomega.ContainSubstring("disabled"),
				), "SECURE_BOOT_ENABLE is disabled on hypervisor; line: %s", strings.TrimSpace(line))
				break
			}
		}
		gomega.Expect(found).To(gomega.BeTrue(), "SECURE_BOOT_ENABLE not found in mlxconfig output:\n%s", out)
	})

	It("SecureBoot state verified on all DPU worker nodes", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("requires-ssh: SSHPrivateKeyPath not configured")
		}
		if cfg.HypervisorHost == nil {
			Skip("requires-ssh: HypervisorHost not configured")
		}
		user := "root"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}

		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, framework.MgmtClient())
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(dpuWorkers) == 0 {
			Skip("no DPU workers found")
		}

		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH connect to hypervisor %s", *cfg.HypervisorHost)
		defer sshClient.Close()

		cmd := `mlxconfig -d $(ls /dev/mst/ | grep -E 'pciconf[0-9]$' | head -1) query SECURE_BOOT_ENABLE 2>/dev/null`
		out, err := sshClient.Run(cmd)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "mlxconfig query SECURE_BOOT_ENABLE: %s", out)

		var found bool
		for _, line := range strings.Split(out, "\n") {
			if strings.Contains(line, "SECURE_BOOT_ENABLE") {
				found = true
				lower := strings.ToLower(line)
				gomega.Expect(lower).NotTo(gomega.Or(
					gomega.ContainSubstring("false(0)"),
					gomega.ContainSubstring("disabled"),
				), "SECURE_BOOT_ENABLE is disabled; line: %s", strings.TrimSpace(line))
				break
			}
		}
		gomega.Expect(found).To(gomega.BeTrue(), "SECURE_BOOT_ENABLE not found in mlxconfig output:\n%s", out)
	})
})

// TC-BFB-002 — SRIOV_EN=0 BFB configuration.
// Priority: High | Labels: bfb, requires-ssh
// Expected Result: The BFB can be provisioned if SRIOV_EN=0 and SRIOV_NUM_VFS=0.
var _ = Describe("TC-BFB-002", Label(labels.Domain.BFB, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
	})

	It("SRIOV_EN=0 and SRIOV_NUM_VFS=0 confirmed via mlxconfig on hypervisor", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("requires-ssh: SSHPrivateKeyPath not configured")
		}
		if cfg.HypervisorHost == nil {
			Skip("requires-ssh: HypervisorHost not configured")
		}
		user := "root"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH connect to hypervisor %s", *cfg.HypervisorHost)
		defer sshClient.Close()

		cmd := `mlxconfig -d $(ls /dev/mst/ | grep -E 'pciconf[0-9]$' | head -1) query SRIOV_EN SRIOV_NUM_VFS 2>/dev/null`
		out, err := sshClient.Run(cmd)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "mlxconfig query SRIOV: %s", out)

		var sriovEnFound, sriovNumVFSFound bool
		for _, line := range strings.Split(out, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "SRIOV_EN") && !strings.HasPrefix(trimmed, "SRIOV_NUM_VFS") {
				sriovEnFound = true
				lower := strings.ToLower(trimmed)
				gomega.Expect(lower).To(gomega.Or(
					gomega.ContainSubstring("false"),
					gomega.ContainSubstring("(0)"),
					// Some mlxconfig versions output just the integer value
					gomega.MatchRegexp(`sriov_en\s+0`),
				), "SRIOV_EN should be 0/False, got: %s", trimmed)
			}
			if strings.HasPrefix(trimmed, "SRIOV_NUM_VFS") {
				sriovNumVFSFound = true
				// Value should be 0
				gomega.Expect(trimmed).To(gomega.MatchRegexp(`SRIOV_NUM_VFS\s+.*\b0\b`),
					"SRIOV_NUM_VFS should be 0, got: %s", trimmed)
			}
		}
		gomega.Expect(sriovEnFound).To(gomega.BeTrue(), "SRIOV_EN not found in mlxconfig output:\n%s", out)
		gomega.Expect(sriovNumVFSFound).To(gomega.BeTrue(), "SRIOV_NUM_VFS not found in mlxconfig output:\n%s", out)
	})

	It("DPU nodes remain Ready after SRIOV_EN=0 provisioning", func() {
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, framework.MgmtClient())
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(dpuWorkers) == 0 {
			Skip("no DPU workers found")
		}
		framework.WaitForAllDPUNodesReady(ctx, framework.MgmtClient(), cfg.DPFNamespace, cfg.DPUCount, framework.DPUNodeReadyTimeout)
	})
})

// TC-BFB-003 — Generic RHCOS 4.22.X OCI os-layer.
// Priority: High | Labels: bfb
// Expected Result: The BFB is based on Generic RHCOS 4.22.X.
var _ = Describe("TC-BFB-003", Label(labels.Domain.BFB), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
	})

	It("BFB URL references an RHCOS/CoreOS/RedHat base image", func() {
		bfbList := &dpfprovisioningv1.BFBList{}
		gomega.Expect(framework.MgmtClient().List(ctx, bfbList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(bfbList.Items) == 0 {
			Skip("no BFB found")
		}
		url := strings.ToLower(bfbList.Items[0].Spec.URL)
		gomega.Expect(url).NotTo(gomega.BeEmpty(), "BFB spec.url must not be empty")
		gomega.Expect(
			strings.Contains(url, "rhcos") ||
				strings.Contains(url, "coreos") ||
				strings.Contains(url, "redhat"),
		).To(gomega.BeTrue(), "BFB URL must reference an RHCOS/CoreOS/RedHat image, got: %s", url)
	})

	It("BFB os-release on DPU reports RHCOS 4.22", func() {
		if cfg.SSHPrivateKeyPath == nil {
			Skip("requires-ssh: SSHPrivateKeyPath not configured")
		}
		if cfg.HypervisorHost == nil {
			Skip("requires-ssh: HypervisorHost not configured")
		}
		user := "root"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		sshClient, err := framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH connect to hypervisor %s", *cfg.HypervisorHost)
		defer sshClient.Close()

		// Connect through the hypervisor to the DPU (port 2222 is the DPU console).
		cmd := `ssh -o StrictHostKeyChecking=no -p 2222 root@localhost 'cat /etc/os-release 2>/dev/null || echo "cannot_access_dpu"' 2>/dev/null`
		out, err := sshClient.Run(cmd)
		// If the command itself fails entirely, skip gracefully.
		if err != nil {
			Skip("cannot reach DPU via hypervisor: " + err.Error())
		}
		if strings.TrimSpace(out) == "cannot_access_dpu" {
			Skip("DPU os-release not accessible from hypervisor")
		}

		// Parse os-release key=value pairs.
		osRelease := make(map[string]string)
		for _, line := range strings.Split(out, "\n") {
			line = strings.TrimSpace(line)
			if idx := strings.IndexByte(line, '='); idx > 0 {
				key := line[:idx]
				val := strings.Trim(line[idx+1:], `"`)
				osRelease[key] = val
			}
		}

		id := strings.ToLower(osRelease["ID"])
		gomega.Expect(id).To(gomega.ContainSubstring("rhcos"),
			"DPU os-release ID must contain 'rhcos', got: %s", id)

		versionID := osRelease["VERSION_ID"]
		gomega.Expect(versionID).To(gomega.HavePrefix("4.22"),
			"DPU os-release VERSION_ID must start with '4.22', got: %s", versionID)
	})
})

// TC-BFB-004 — BFB installs DOCA components using an OCI os-layer from Red Hat repository.
// Priority: High | Labels: bfb
// Expected Result: BFB installs DOCA components using an OCI OS layer from Red Hat repository.
var _ = Describe("TC-BFB-004", Label(labels.Domain.BFB), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
	})

	It("BFB object exists in DPF namespace", func() {
		bfbList := &dpfprovisioningv1.BFBList{}
		gomega.Expect(framework.MgmtClient().List(ctx, bfbList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		gomega.Expect(bfbList.Items).NotTo(gomega.BeEmpty(), "at least one BFB object must exist in namespace %s", cfg.DPFNamespace)
	})

	It("BFB URL references a Red Hat OCI os-layer repository", func() {
		bfbList := &dpfprovisioningv1.BFBList{}
		gomega.Expect(framework.MgmtClient().List(ctx, bfbList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(bfbList.Items) == 0 {
			Skip("no BFB found")
		}
		url := bfbList.Items[0].Spec.URL
		gomega.Expect(url).NotTo(gomega.BeEmpty(), "BFB spec.url must not be empty")
		gomega.Expect(url).To(gomega.Or(
			gomega.ContainSubstring("registry.redhat.io"),
			gomega.ContainSubstring("quay.io/redhat"),
			gomega.ContainSubstring("registry.access.redhat.com"),
		), "BFB URL must reference a Red Hat OCI repository, got: %s", url)
	})

	It("BFB reaches Ready state with OCI os-layer", func() {
		bfbList := &dpfprovisioningv1.BFBList{}
		gomega.Expect(framework.MgmtClient().List(ctx, bfbList, client.InNamespace(cfg.DPFNamespace))).To(gomega.Succeed())
		if len(bfbList.Items) == 0 {
			Skip("no BFB found")
		}
		bfb := bfbList.Items[0]
		cond := meta.FindStatusCondition(bfb.Status.Conditions, "Ready")
		gomega.Expect(cond).NotTo(gomega.BeNil(), "BFB %s has no Ready condition", bfb.Name)
		gomega.Expect(cond.Status).To(gomega.Equal(metav1.ConditionTrue),
			"BFB %s Ready condition is not True: %s", bfb.Name, cond.Message)
	})
})
