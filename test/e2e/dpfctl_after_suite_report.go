package e2e

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	dpfctlVersion     = "v26.4.0"
	dpfctlDownloadURL = "https://api.ngc.nvidia.com/v2/resources/nvidia/doca/dpfctl/versions/v26.4.0/files/dpfctl-linux-amd64"
	// Published by the NVIDIA NGC v26.4.0 file metadata for dpfctl-linux-amd64.
	dpfctlSHA256            = "076461f113d2fe2dc40ff3726b6760f3a0796b32313a10ce9e14f694f852a6c6"
	dpfctlCommandTimeout    = 45 * time.Minute
	dpfctlDownloadTimeout   = 5 * time.Minute
	dpfctlCleanupTimeout    = 2 * time.Minute
	dpfctlCleanupPollPeriod = 2 * time.Second
	dpfctlSOSReportTimeout  = "30m"
	dpfctlSOSMemoryLimit    = "2Gi"
	dpfctlSOSNamespace      = "default"
	dpfctlSOSCaseIDLabel    = "dpfctl.dpu.nvidia.com/case-id"
	dpfctlSOSManagedLabel   = "app.kubernetes.io/managed-by=dpfctl"
	dpfctlSOSComponentLabel = "dpfctl.dpu.nvidia.com/component=sosreport"
)

var (
	dpfctlArtifactOnce sync.Once
	dpfctlArtifactPath string
	dpfctlArtifactErr  error

	dpfctlBinaryOnce    sync.Once
	dpfctlBinaryPath    string
	dpfctlBinaryTempDir string
	dpfctlBinaryErr     error
)

type commandResult struct {
	Command []string
	Stdout  string
	Stderr  string
	Err     error
}

type commandRunner interface {
	Run(ctx context.Context, executable string, args []string, env []string) commandResult
}

type osCommandRunner struct{}

func (osCommandRunner) Run(ctx context.Context, executable string, args []string, env []string) commandResult {
	cmd := exec.CommandContext(ctx, executable, args...)
	cmd.Env = append(os.Environ(), env...)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if ctx.Err() != nil {
		err = fmt.Errorf("command timed out or was cancelled: %w", ctx.Err())
	}

	return commandResult{
		Command: append([]string{executable}, args...),
		Stdout:  stdout.String(),
		Stderr:  stderr.String(),
		Err:     err,
	}
}

type sosReportCase struct {
	Name             string
	CaseID           string
	Args             []string
	CleanupArgs      []string
	ArtifactDir      string
	OutputDir        string
	DiagnosticTarget string
}

func dpfctlArtifactDir() (string, error) {
	dpfctlArtifactOnce.Do(func() {
		base := os.Getenv("ARTIFACT_DIR")
		if base == "" {
			base, dpfctlArtifactErr = os.MkdirTemp("", "openshift-dpf-e2e-artifacts-")
			if dpfctlArtifactErr != nil {
				return
			}
		}
		dpfctlArtifactPath = filepath.Join(base, "dpfctl")
		dpfctlArtifactErr = os.MkdirAll(dpfctlArtifactPath, 0o755)
	})
	return dpfctlArtifactPath, dpfctlArtifactErr
}

func standaloneDPFCTLBinary(ctx context.Context) (string, error) {
	dpfctlBinaryOnce.Do(func() {
		dpfctlBinaryTempDir, dpfctlBinaryErr = os.MkdirTemp("", "dpfctl-e2e-")
		if dpfctlBinaryErr != nil {
			dpfctlBinaryErr = fmt.Errorf("create dpfctl temporary directory: %w", dpfctlBinaryErr)
			return
		}

		dpfctlBinaryPath = filepath.Join(dpfctlBinaryTempDir, "dpfctl")
		downloadCtx, cancelDownload := context.WithTimeout(ctx, dpfctlDownloadTimeout)
		defer cancelDownload()
		if err := downloadFile(downloadCtx, dpfctlDownloadURL, dpfctlBinaryPath, dpfctlSHA256); err != nil {
			dpfctlBinaryErr = fmt.Errorf("download standalone dpfctl %s: %w", dpfctlVersion, err)
			_ = os.RemoveAll(dpfctlBinaryTempDir)
			dpfctlBinaryPath = ""
			dpfctlBinaryTempDir = ""
		}
	})
	return dpfctlBinaryPath, dpfctlBinaryErr
}

func cleanupStandaloneDPFCTLBinary() {
	if dpfctlBinaryTempDir != "" {
		_ = os.RemoveAll(dpfctlBinaryTempDir)
	}
}

func buildSOSReportCases(hostNodes, dpuNodes []string, artifactDir, runID string) []sosReportCase {
	newCase := func(name, caseID, caseArtifactDir, diagnosticTarget string, targetArgs []string) sosReportCase {
		outputDir := filepath.Join(caseArtifactDir, "reports")
		args := []string{"sosreport", "collect"}
		args = append(args, targetArgs...)
		args = append(args,
			"--case-id", caseID,
			"--timeout", dpfctlSOSReportTimeout,
			"--limits.memory", dpfctlSOSMemoryLimit,
			"--cleanup=false",
			"--archive",
			"--archive-only",
			"--output-dir", outputDir,
		)
		return sosReportCase{
			Name:             name,
			CaseID:           caseID,
			Args:             args,
			CleanupArgs:      append([]string{"sosreport", "cleanup"}, append(targetArgsForCleanup(targetArgs), "--case-id", caseID)...),
			ArtifactDir:      caseArtifactDir,
			OutputDir:        outputDir,
			DiagnosticTarget: diagnosticTarget,
		}
	}

	cases := make([]sosReportCase, 0, len(hostNodes)+len(dpuNodes))
	for i, node := range hostNodes {
		cases = append(cases, newCase(
			"no-target-host/"+node,
			fmt.Sprintf("e2e-dpfctl-host-%s-%d", runID, i),
			filepath.Join(artifactDir, "no-target-host", node),
			"host",
			[]string{"--nodes", node},
		))
	}
	for i, node := range dpuNodes {
		cases = append(cases, newCase(
			"target-dpu/"+node,
			fmt.Sprintf("e2e-dpfctl-dpu-%s-%d", runID, i),
			filepath.Join(artifactDir, "target-dpu", node),
			"dpu",
			[]string{"--target", "dpu", "--nodes", node},
		))
	}
	return cases
}

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
	fmt.Printf("TC-LOG-001 dpfctl artifacts: %s\n", artifactDir)

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
		hostedKubeconfigPath, removeHostedKubeconfig, err := temporaryKubeconfig(hostedKubeconfig)
		if err != nil {
			return fmt.Errorf("prepare hosted kubeconfig for SOS pod diagnostics: %w", err)
		}
		defer removeHostedKubeconfig()
		diagnosticKubeconfigs["dpu"] = hostedKubeconfigPath
	}

	// dpfctl must start from the management cluster for --target dpu. It discovers
	// DPUCluster resources there, then reads and injects the hosted kubeconfig into
	// each DPU SOS Job itself.
	env := []string{"KUBECONFIG=" + managementKubeconfig}
	runID := time.Now().UTC().Format("20060102-150405")
	cases := buildSOSReportCases(hostNodes, dpuNodes, artifactDir, runID)
	if len(cases) == 0 {
		return errors.New("no SOS report cases were requested")
	}
	var strictErrors []error

	for _, testCase := range cases {
		// --archive-only removes OutputDir and writes reports.tar.gz beside it,
		// so the enclosing per-case directory is the cleanup and verification boundary.
		if err := os.RemoveAll(testCase.ArtifactDir); err != nil {
			strictErrors = append(strictErrors, fmt.Errorf("clear %s artifact directory: %w", testCase.Name, err))
			continue
		}
		if err := os.MkdirAll(testCase.ArtifactDir, 0o755); err != nil {
			strictErrors = append(strictErrors, fmt.Errorf("create %s output directory: %w", testCase.Name, err))
			continue
		}

		fmt.Printf("Running TC-LOG-001 SOS case %s\n", testCase.Name)
		result := runWithTimeout(ctx, runner, binaryPath, testCase.Args, env)

		// dpfctl can emit benign warnings on stderr, including a missing optional
		// /etc/dpf-defaults.yaml. Only the process exit status and archive validation
		// determine whether this case failed.
		caseErr := result.Err
		if err := writeCommandLog(filepath.Join(testCase.ArtifactDir, "command.log"), result); err != nil {
			caseErr = errors.Join(caseErr, err)
		}
		if caseErr == nil {
			archivePath := testCase.OutputDir + ".tar.gz"
			archiveInfo, archiveErr := os.Stat(archivePath)
			if archiveErr != nil {
				caseErr = fmt.Errorf("verify SOS report archive %s: %w", archivePath, archiveErr)
			} else if archiveInfo.Size() == 0 {
				caseErr = fmt.Errorf("SOS report archive %s is empty", archivePath)
			}
		}
		if caseErr != nil {
			describeResult := describeSOSPods(ctx, runner, diagnosticKubeconfigs[testCase.DiagnosticTarget], testCase.CaseID)
			if err := writeCommandLog(filepath.Join(testCase.ArtifactDir, "pod-describe-on-failure.log"), describeResult); err != nil {
				caseErr = errors.Join(caseErr, err)
			} else if describeResult.Err != nil {
				caseErr = errors.Join(caseErr, fmt.Errorf("describe failed SOS pods: %w", describeResult.Err))
			}
		}

		// --cleanup=false keeps failed pods available for the diagnostic above.
		// Cleanup is always scoped by this case's unique case ID; target arguments
		// further restrict DPU cases to the hosted cluster.
		cleanupResult := runWithTimeout(ctx, runner, binaryPath, testCase.CleanupArgs, env)
		if err := writeCommandLog(filepath.Join(testCase.ArtifactDir, "cleanup.log"), cleanupResult); err != nil {
			caseErr = errors.Join(caseErr, err)
		} else if cleanupResult.Err != nil {
			caseErr = errors.Join(caseErr, fmt.Errorf("cleanup failed: %w", cleanupResult.Err))
		}

		cleanupVerification := verifySOSResourcesDeleted(ctx, runner, diagnosticKubeconfigs[testCase.DiagnosticTarget], testCase.CaseID)
		if err := writeCommandLog(filepath.Join(testCase.ArtifactDir, "cleanup-verification.log"), cleanupVerification); err != nil {
			caseErr = errors.Join(caseErr, err)
		} else if cleanupVerification.Err != nil {
			caseErr = errors.Join(caseErr, cleanupVerification.Err)
		}

		if caseErr != nil {
			strictErrors = append(strictErrors, fmt.Errorf("%s SOS collection failed: %w", testCase.Name, caseErr))
		}
	}

	return errors.Join(strictErrors...)
}

func temporaryKubeconfig(contents []byte) (string, func(), error) {
	file, err := os.CreateTemp("", "openshift-dpf-hosted-kubeconfig-")
	if err != nil {
		return "", nil, err
	}
	path := file.Name()
	remove := func() { _ = os.Remove(path) }
	if _, err := file.Write(contents); err != nil {
		_ = file.Close()
		remove()
		return "", nil, err
	}
	if err := file.Close(); err != nil {
		remove()
		return "", nil, err
	}
	return path, remove, nil
}

func sosResourceSelector(caseID string) string {
	return strings.Join([]string{
		dpfctlSOSManagedLabel,
		dpfctlSOSComponentLabel,
		dpfctlSOSCaseIDLabel + "=" + caseID,
	}, ",")
}

func describeSOSPods(ctx context.Context, runner commandRunner, kubeconfig, caseID string) commandResult {
	return runWithTimeout(ctx, runner, "oc", []string{
		"--kubeconfig", kubeconfig,
		"describe", "pods",
		"--namespace", dpfctlSOSNamespace,
		"--selector", sosResourceSelector(caseID),
	}, nil)
}

func verifySOSResourcesDeleted(ctx context.Context, runner commandRunner, kubeconfig, caseID string) commandResult {
	verificationCtx, cancel := context.WithTimeout(ctx, dpfctlCleanupTimeout)
	defer cancel()
	args := []string{
		"--kubeconfig", kubeconfig,
		"get", "jobs,pods,secrets",
		"--namespace", dpfctlSOSNamespace,
		"--selector", sosResourceSelector(caseID),
		"--output", "name",
	}

	var result commandResult
	for {
		result = runner.Run(verificationCtx, "oc", args, nil)
		if result.Err != nil || strings.TrimSpace(result.Stdout) == "" {
			return result
		}

		select {
		case <-verificationCtx.Done():
			result.Err = fmt.Errorf("SOS resources remain after %s: %s", dpfctlCleanupTimeout, strings.TrimSpace(result.Stdout))
			return result
		case <-time.After(dpfctlCleanupPollPeriod):
		}
	}
}

func runStandaloneDPFCTLDescribeAll(ctx context.Context, runner commandRunner, kubeconfig string) error {
	if kubeconfig == "" {
		return errors.New("management-cluster KUBECONFIG is empty")
	}

	rootArtifactDir, err := dpfctlArtifactDir()
	if err != nil {
		return fmt.Errorf("create dpfctl artifact directory: %w", err)
	}
	artifactDir := filepath.Join(rootArtifactDir, "tc-log-002")
	if err := os.RemoveAll(artifactDir); err != nil {
		return fmt.Errorf("clear TC-LOG-002 artifact directory: %w", err)
	}
	if err := os.MkdirAll(artifactDir, 0o755); err != nil {
		return fmt.Errorf("create TC-LOG-002 artifact directory: %w", err)
	}
	fmt.Printf("TC-LOG-002 dpfctl artifacts: %s\n", artifactDir)

	binaryPath, err := standaloneDPFCTLBinary(ctx)
	if err != nil {
		return err
	}
	result := runWithTimeout(ctx, runner, binaryPath, []string{"describe", "all"}, []string{"KUBECONFIG=" + kubeconfig})
	if err := writeCommandLog(filepath.Join(artifactDir, "standalone-describe-all.log"), result); err != nil {
		return err
	}
	if result.Err != nil {
		return fmt.Errorf("standalone dpfctl describe all: %w", result.Err)
	}
	if strings.TrimSpace(result.Stdout) == "" {
		return errors.New("standalone dpfctl describe all returned no output")
	}
	return nil
}

func targetArgsForCleanup(collectTargetArgs []string) []string {
	for i := 0; i+1 < len(collectTargetArgs); i++ {
		if collectTargetArgs[i] == "--target" {
			return []string{"--target", collectTargetArgs[i+1]}
		}
	}
	return nil
}

func runWithTimeout(ctx context.Context, runner commandRunner, executable string, args, env []string) commandResult {
	commandCtx, cancel := context.WithTimeout(ctx, dpfctlCommandTimeout)
	defer cancel()
	return runner.Run(commandCtx, executable, args, env)
}

func downloadFile(ctx context.Context, url, destination, expectedSHA256 string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("download returned HTTP %s", response.Status)
	}

	temporary := destination + ".download"
	file, err := os.OpenFile(temporary, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	hasher := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(file, hasher), response.Body)
	closeErr := file.Close()
	if copyErr != nil {
		_ = os.Remove(temporary)
		return copyErr
	}
	if closeErr != nil {
		_ = os.Remove(temporary)
		return closeErr
	}
	actualSHA256 := hex.EncodeToString(hasher.Sum(nil))
	if actualSHA256 != expectedSHA256 {
		_ = os.Remove(temporary)
		return fmt.Errorf("downloaded artifact SHA-256 is %s, want %s", actualSHA256, expectedSHA256)
	}
	if err := os.Rename(temporary, destination); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func writeCommandLog(path string, result commandResult) error {
	var log strings.Builder
	log.WriteString("$ ")
	log.WriteString(strings.Join(result.Command, " "))
	log.WriteString("\n\nstdout:\n")
	log.WriteString(result.Stdout)
	log.WriteString("\n\nstderr:\n")
	log.WriteString(result.Stderr)
	if result.Err != nil {
		log.WriteString("\n\nerror:\n")
		log.WriteString(result.Err.Error())
	}
	log.WriteString("\n")
	if err := os.WriteFile(path, []byte(log.String()), 0o644); err != nil {
		return fmt.Errorf("write command log %s: %w", path, err)
	}
	return nil
}

func appendExecutionLog(artifactDir, message string) error {
	path := filepath.Join(artifactDir, "execution.log")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open execution log: %w", err)
	}
	defer file.Close()
	if _, err := fmt.Fprintf(file, "%s %s", time.Now().UTC().Format(time.RFC3339), message); err != nil {
		return fmt.Errorf("append execution log: %w", err)
	}
	return nil
}
