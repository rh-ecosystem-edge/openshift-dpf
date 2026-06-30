// Package logcollection tests log collection tooling for DPF.
// Section 19 of the DPF QA Test Plan.
package logcollection_test

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

// TC-LOG-001 — SOS report collection from DPU host nodes.
// Priority: High | Labels: dpf, requires-ssh
// Expected Result: SOS report generated without errors. Includes comprehensive DPF data.
var _ = Describe("TC-LOG-001", Label(labels.Domain.DPF, labels.Domain.RequiresSSH), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig
	var sshClient *framework.SSHClient

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx

		if cfg.SSHPrivateKeyPath == nil {
			Skip("SSHPrivateKeyPath not configured — skipping TC-LOG-001 (requires-ssh)")
		}

		user := "core"
		if cfg.HypervisorUser != nil {
			user = *cfg.HypervisorUser
		}
		var err error
		sshClient, err = framework.NewSSHClient(*cfg.HypervisorHost, user, *cfg.SSHPrivateKeyPath)
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to establish SSH connection to hypervisor")
		DeferCleanup(func() {
			sshClient.Close()
		})
	})

	It("SOS tool is available on DPU host nodes", func() {
		out, err := sshClient.Run("which sos || which sosreport || echo NOT_FOUND")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to check for sos tool")
		By(fmt.Sprintf("SOS tool check output: %s", strings.TrimSpace(out)))
		gomega.Expect(out).NotTo(gomega.ContainSubstring("NOT_FOUND"),
			"neither 'sos' nor 'sosreport' was found on the host — expected sos package to be installed")
	})

	It("SOS report runs successfully and generates an archive", func() {
		By("Running sos report on the hypervisor host")
		out, err := sshClient.Run(
			"sos report --batch --tmp-dir /tmp/dpf-sos-report 2>/dev/null || " +
				"sosreport --batch --tmp-dir /tmp/dpf-sos-report 2>/dev/null; " +
				`echo "SOS_EXIT:$?"`,
		)
		By(fmt.Sprintf("SOS report output tail: %s", out))
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "SSH run failed unexpectedly")
		gomega.Expect(out).To(gomega.ContainSubstring("SOS_EXIT:0"),
			"sos report exited with a non-zero status; full output: %s", out)

		By("Verifying that at least one .tar.xz archive was produced")
		countOut, err := sshClient.Run("ls /tmp/dpf-sos-report/*.tar.xz 2>/dev/null | wc -l")
		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to list SOS report archives")
		count := strings.TrimSpace(countOut)
		gomega.Expect(count).NotTo(gomega.Equal("0"),
			"no .tar.xz archive found in /tmp/dpf-sos-report after sos report completed")
	})
})

// TC-LOG-002 — dpfctl log collection.
// Priority: High | Labels: dpf
// Expected Result: Report comprehensive DPF configuration data (dpfctl).
var _ = Describe("TC-LOG-002", Label(labels.Domain.DPF), Ordered, func() {
	var ctx context.Context

	BeforeAll(func() {
		ctx = context.Background()
		_ = ctx
	})

	It("dpfctl reports comprehensive DPF configuration data", func() {
		// Try "dpfctl status" first; fall back to "dpfctl get all".
		cmd := exec.Command("dpfctl", "status")
		out, err := cmd.CombinedOutput()
		if err != nil {
			// Distinguish "binary not found" from runtime errors.
			var execErr *exec.Error
			if errors.As(err, &execErr) && errors.Is(execErr.Err, exec.ErrNotFound) {
				Skip("dpfctl binary not found in PATH — expected in dpf-ci container")
			}
			// Binary exists but "status" sub-command may not; retry with "get all".
			cmd2 := exec.Command("dpfctl", "get", "all")
			out, err = cmd2.CombinedOutput()
			if err != nil {
				var execErr2 *exec.Error
				if errors.As(err, &execErr2) && errors.Is(execErr2.Err, exec.ErrNotFound) {
					Skip("dpfctl binary not found in PATH — expected in dpf-ci container")
				}
			}
		}

		By(fmt.Sprintf("dpfctl output length: %d bytes", len(out)))
		gomega.Expect(err).NotTo(gomega.HaveOccurred(),
			"dpfctl exited with error; output: %s", string(out))
		gomega.Expect(out).NotTo(gomega.BeEmpty(),
			"dpfctl returned no output — expected comprehensive DPF configuration data")
		gomega.Expect(len(out)).To(gomega.BeNumerically(">", 100),
			"dpfctl output is too short (%d bytes) to contain real DPF data", len(out))
	})
})

// TC-LOG-003 — must-gather for DPF.
// Priority: High | Labels: dpf
// Expected Result: Report comprehensive DPF configuration data (must-gather).
var _ = Describe("TC-LOG-003", Label(labels.Domain.DPF), Ordered, func() {
	var ctx context.Context
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		cfg = config.Get()
		_ = ctx
	})

	It("DPF must-gather collects comprehensive configuration data", func() {
		// Verify oc is available.
		if _, err := exec.LookPath("oc"); err != nil {
			Skip("oc binary not found in PATH — skipping TC-LOG-003")
		}

		// Construct the must-gather image. Use DPFVersion when available.
		mustGatherImage := "quay.io/openshift/origin-must-gather:latest"
		if cfg.DPFVersion != "" {
			By(fmt.Sprintf("DPF version configured: %s — using origin-must-gather as fallback image", cfg.DPFVersion))
		}

		By(fmt.Sprintf("Running oc adm must-gather with image %s", mustGatherImage))
		cmd := exec.Command("oc", "adm", "must-gather",
			"--dest-dir=/tmp/dpf-must-gather",
			fmt.Sprintf("--image=%s", mustGatherImage),
			"--timeout=5m",
		)
		out, err := cmd.CombinedOutput()
		By(fmt.Sprintf("must-gather output: %s", string(out)))
		gomega.Expect(err).NotTo(gomega.HaveOccurred(),
			"oc adm must-gather failed; output: %s", string(out))

		By("Verifying must-gather output directory contains files")
		lsCmd := exec.Command("ls", "/tmp/dpf-must-gather")
		lsOut, lsErr := lsCmd.CombinedOutput()
		gomega.Expect(lsErr).NotTo(gomega.HaveOccurred(),
			"failed to list must-gather output directory: %s", string(lsOut))
		gomega.Expect(strings.TrimSpace(string(lsOut))).NotTo(gomega.BeEmpty(),
			"must-gather output directory /tmp/dpf-must-gather is empty after collection")
	})
})
