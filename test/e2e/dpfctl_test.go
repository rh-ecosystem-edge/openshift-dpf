package e2e

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/openshift-dpf/test/utils"
)

const dpfctlAllTargetBugURL = "https://partners.nvidia.com/Bug/ViewBug/6439986?siteID=310998"

type sosReportTask struct {
	Name             string
	CaseID           string
	Args             []string
	CleanupArgs      []string
	ArtifactDir      string
	OutputDir        string
	DiagnosticTarget string
}

var _ = Describe("TC-LOG-001: dpfctl SOS Report Collection", Label("dpfctl"), func() {
	It("collects a standalone SOS report from every host worker", func() {
		if len(dpuHostWorkers) == 0 {
			Skip("SOS collection requires at least one DPU-enabled host worker")
		}

		hostNodes := make([]string, 0, len(dpuHostWorkers))
		for _, node := range dpuHostWorkers {
			hostNodes = append(hostNodes, node.Name)
		}

		By("Collecting a standalone SOS report from every discovered host worker")
		Expect(runStandaloneDPFCTLSOSReports(ctx, osCommandRunner{}, cfg.Kubeconfig, nil, hostNodes, nil)).To(Succeed())
	})

	It("collects a standalone SOS report from every DPU worker", func() {
		if len(dpuWorkers) == 0 {
			Skip("SOS collection requires at least one ready DPU worker")
		}

		dpuNodes := make([]string, 0, len(dpuWorkers))
		for _, node := range dpuWorkers {
			dpuNodes = append(dpuNodes, node.Name)
		}

		By("Collecting a standalone SOS report from every discovered DPU worker")
		Expect(runStandaloneDPFCTLSOSReports(ctx, osCommandRunner{}, cfg.Kubeconfig, hostedKubeconfigBytes, nil, dpuNodes)).To(Succeed())
	})

	It("collects standalone SOS reports from all targets", func() {
		Skip(fmt.Sprintf("NVBUG 6439986: all-target dpfctl SOS collection is disabled until the known issue is fixed: %s", dpfctlAllTargetBugURL))
	})
})

func runStandaloneDPFCTLSOSReports(ctx context.Context, runner commandRunner, managementKubeconfig string, hostedKubeconfig []byte, hostNodes, dpuNodes []string) error {
	if managementKubeconfig == "" {
		return errors.New("management-cluster KUBECONFIG is empty")
	}

	rootArtifactDir, err := dpfctlArtifactDir()
	if err != nil {
		return fmt.Errorf("create dpfctl artifact directory: %w", err)
	}
	artifactDir := filepath.Join(rootArtifactDir, "tc-log-001")
	if err := os.MkdirAll(artifactDir, 0o755); err != nil {
		return fmt.Errorf("create TC-LOG-001 artifact directory: %w", err)
	}
	GinkgoWriter.Printf("TC-LOG-001 dpfctl artifacts: %s\n", artifactDir)

	binaryPath, err := standaloneDPFCTLBinary(ctx)
	if err != nil {
		_ = appendExecutionLog(artifactDir, fmt.Sprintf("download failed: %v\n", err))
		return err
	}

	if err := appendExecutionLog(artifactDir, fmt.Sprintf("TC-LOG-001 standalone dpfctl SOS collection (%s)\n", dpfctlVersion)); err != nil {
		return err
	}

	diagnosticKubeconfigs := map[string]string{"host": managementKubeconfig}
	if len(dpuNodes) > 0 {
		if len(hostedKubeconfig) == 0 {
			return errors.New("hosted-cluster kubeconfig is empty")
		}
		hostedKubeconfigPath, removeHostedKubeconfig, err := utils.WriteTempKubeconfig(hostedKubeconfig)
		if err != nil {
			return fmt.Errorf("prepare hosted kubeconfig for SOS pod diagnostics: %w", err)
		}
		defer removeHostedKubeconfig()
		diagnosticKubeconfigs["dpu"] = hostedKubeconfigPath
	} else {
		GinkgoWriter.Printf("No DPU worker nodes provided; skipping DPU SOS report collection\n")
	}

	// dpfctl must start from the management cluster for --target dpu. It discovers
	// DPUCluster resources there, then reads and injects the hosted kubeconfig into
	// each DPU SOS Job itself.
	env := []string{"KUBECONFIG=" + managementKubeconfig}
	runID := time.Now().UTC().Format("20060102-150405")
	tasks := buildSOSReportTasks(hostNodes, dpuNodes, artifactDir, runID)
	if len(tasks) == 0 {
		return errors.New("no SOS report tasks were requested")
	}
	var strictErrors []error

	for _, task := range tasks {
		// --archive-only removes OutputDir and writes reports.tar.gz beside it,
		// so the enclosing per-task directory is the cleanup and verification boundary.
		if err := os.RemoveAll(task.ArtifactDir); err != nil {
			strictErrors = append(strictErrors, fmt.Errorf("clear %s artifact directory: %w", task.Name, err))
			continue
		}
		if err := os.MkdirAll(task.ArtifactDir, 0o755); err != nil {
			strictErrors = append(strictErrors, fmt.Errorf("create %s output directory: %w", task.Name, err))
			continue
		}

		GinkgoWriter.Printf("Running TC-LOG-001 SOS task %s\n", task.Name)
		result := runWithTimeout(ctx, runner, binaryPath, task.Args, env)

		// dpfctl can emit benign warnings on stderr, including a missing optional
		// /etc/dpf-defaults.yaml. Only the process exit status and archive validation
		// determine whether this task failed.
		taskErr := result.Err
		if err := writeCommandLog(filepath.Join(task.ArtifactDir, "command.log"), result); err != nil {
			taskErr = errors.Join(taskErr, err)
		}
		if taskErr == nil {
			archivePath := task.OutputDir + ".tar.gz"
			archiveInfo, archiveErr := os.Stat(archivePath)
			if archiveErr != nil {
				taskErr = fmt.Errorf("verify SOS report archive %s: %w", archivePath, archiveErr)
			} else if archiveInfo.Size() == 0 {
				taskErr = fmt.Errorf("SOS report archive %s is empty", archivePath)
			}
		}
		if taskErr != nil {
			if err := captureSOSFailureDiagnostics(ctx, runner, diagnosticKubeconfigs[task.DiagnosticTarget], task); err != nil {
				taskErr = errors.Join(taskErr, err)
			}
		}

		// --cleanup=false keeps failed pods available for the diagnostic above.
		// Cleanup is always scoped by this task's unique case ID; target arguments
		// further restrict DPU cases to the hosted cluster.
		cleanupResult := runWithTimeout(ctx, runner, binaryPath, task.CleanupArgs, env)
		if err := writeCommandLog(filepath.Join(task.ArtifactDir, "cleanup.log"), cleanupResult); err != nil {
			taskErr = errors.Join(taskErr, err)
		} else if cleanupResult.Err != nil {
			taskErr = errors.Join(taskErr, fmt.Errorf("cleanup failed: %w", cleanupResult.Err))
		}

		cleanupVerification := verifySOSResourcesDeleted(ctx, runner, diagnosticKubeconfigs[task.DiagnosticTarget], task.CaseID)
		if err := writeCommandLog(filepath.Join(task.ArtifactDir, "cleanup-verification.log"), cleanupVerification); err != nil {
			taskErr = errors.Join(taskErr, err)
		} else if cleanupVerification.Err != nil {
			taskErr = errors.Join(taskErr, cleanupVerification.Err)
		}

		if taskErr != nil {
			strictErrors = append(strictErrors, fmt.Errorf("%s SOS collection failed: %w", task.Name, taskErr))
		}
	}

	return errors.Join(strictErrors...)
}

func captureSOSFailureDiagnostics(ctx context.Context, runner commandRunner, kubeconfig string, task sosReportTask) error {
	diagnostics := []struct {
		name   string
		path   string
		result commandResult
	}{
		{
			name:   "get SOS pod image IDs",
			path:   filepath.Join(task.ArtifactDir, "pod-image-ids-on-failure.log"),
			result: getSOSPodImageIDs(ctx, runner, kubeconfig, task.CaseID),
		},
		{
			name:   "get SOS container logs",
			path:   filepath.Join(task.ArtifactDir, "sosreport-container-on-failure.log"),
			result: getSOSContainerLogs(ctx, runner, kubeconfig, task.CaseID),
		},
		{
			name:   "describe failed SOS pods",
			path:   filepath.Join(task.ArtifactDir, "pod-describe-on-failure.log"),
			result: describeSOSPods(ctx, runner, kubeconfig, task.CaseID),
		},
	}

	var diagnosticErrors []error
	for _, diagnostic := range diagnostics {
		if err := writeCommandLog(diagnostic.path, diagnostic.result); err != nil {
			diagnosticErrors = append(diagnosticErrors, err)
			continue
		}
		if diagnostic.result.Err != nil {
			diagnosticErrors = append(diagnosticErrors, fmt.Errorf("%s: %w", diagnostic.name, diagnostic.result.Err))
		}
	}
	return errors.Join(diagnosticErrors...)
}

func buildSOSReportTasks(hostNodes, dpuNodes []string, artifactDir, runID string) []sosReportTask {
	newTask := func(name, caseID, caseArtifactDir, diagnosticTarget, reportTimeout string, targetArgs []string) sosReportTask {
		outputDir := filepath.Join(caseArtifactDir, "reports")
		args := []string{"sosreport", "collect"}
		args = append(args, targetArgs...)
		args = append(args,
			"--case-id", caseID,
			"--timeout", reportTimeout,
			"--limits.memory", dpfctlSOSMemoryLimit,
			"--cleanup=false",
			"--archive",
			"--archive-only",
			"--output-dir", outputDir,
		)
		return sosReportTask{
			Name:             name,
			CaseID:           caseID,
			Args:             args,
			CleanupArgs:      append([]string{"sosreport", "cleanup"}, append(targetArgsForCleanup(targetArgs), "--case-id", caseID)...),
			ArtifactDir:      caseArtifactDir,
			OutputDir:        outputDir,
			DiagnosticTarget: diagnosticTarget,
		}
	}

	tasks := make([]sosReportTask, 0, len(hostNodes)+len(dpuNodes))
	for i, node := range hostNodes {
		tasks = append(tasks, newTask(
			"no-target-host/"+node,
			fmt.Sprintf("e2e-dpfctl-host-%s-%d", runID, i),
			filepath.Join(artifactDir, "no-target-host", node),
			"host",
			dpfctlSOSHostTimeout,
			[]string{"--nodes", node},
		))
	}
	for i, node := range dpuNodes {
		tasks = append(tasks, newTask(
			"target-dpu/"+node,
			fmt.Sprintf("e2e-dpfctl-dpu-%s-%d", runID, i),
			filepath.Join(artifactDir, "target-dpu", node),
			"dpu",
			dpfctlSOSDPUTimeout,
			[]string{"--target", "dpu", "--nodes", node},
		))
	}
	return tasks
}
