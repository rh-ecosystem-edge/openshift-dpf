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

	. "github.com/onsi/ginkgo/v2"
)

const (
	dpfctlVersion     = "v26.4.0"
	dpfctlDownloadURL = "https://api.ngc.nvidia.com/v2/resources/nvidia/doca/dpfctl/versions/v26.4.0/files/dpfctl-linux-amd64"
	// Published by the NVIDIA NGC v26.4.0 file metadata for dpfctl-linux-amd64.
	dpfctlSHA256            = "076461f113d2fe2dc40ff3726b6760f3a0796b32313a10ce9e14f694f852a6c6"
	dpfctlCommandTimeout    = 75 * time.Minute
	dpfctlDownloadTimeout   = 5 * time.Minute
	dpfctlCleanupTimeout    = 2 * time.Minute
	dpfctlCleanupPollPeriod = 2 * time.Second
	dpfctlSOSHostTimeout    = "30m"
	dpfctlSOSDPUTimeout     = "1h"
	dpfctlSOSMemoryLimit    = "4Gi"
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

func getSOSPodImageIDs(ctx context.Context, runner commandRunner, kubeconfig, caseID string) commandResult {
	const imageIDJSONPath = `{range .items[*]}pod={.metadata.name}{"\n"}{range .status.initContainerStatuses[?(@.name=="sosreport")]}image={.image}{"\n"}imageID={.imageID}{"\n"}{end}{end}`
	return runWithTimeout(ctx, runner, "oc", []string{
		"--kubeconfig", kubeconfig,
		"get", "pods",
		"--namespace", dpfctlSOSNamespace,
		"--selector", sosResourceSelector(caseID),
		"--output", "jsonpath=" + imageIDJSONPath,
	}, nil)
}

func getSOSContainerLogs(ctx context.Context, runner commandRunner, kubeconfig, caseID string) commandResult {
	return runWithTimeout(ctx, runner, "oc", []string{
		"--kubeconfig", kubeconfig,
		"logs",
		"--namespace", dpfctlSOSNamespace,
		"--selector", sosResourceSelector(caseID),
		"--container", "sosreport",
		"--prefix=true",
		"--timestamps=true",
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
	GinkgoWriter.Printf("TC-LOG-002 dpfctl artifacts: %s\n", artifactDir)

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
