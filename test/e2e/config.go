package e2e

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type TestConfig struct {
	EnvFile             string
	Kubeconfig          string
	HostedClusterName   string
	ClustersNamespace   string
	DPFNamespace        string
	WorkloadNamespace   string
	DPUClusterName      string
	DPUDeploymentName   string
	UpgradeReleaseImage string
	NewBFBURL           string
	NewBFBFileName      string
	NewBFBVersionsBSP   string
	NewBFBVersionsDOCA  string
	NewBFBVersionsUEFI  string
	NewBFBVersionsATF   string
	UpgradeMachineOSURL string
	PingCount           int
	PingHBNToHBN        bool
	WorkerCount         int
	ExternalRouterIP    string
}

var cfg TestConfig

func init() {
	flag.StringVar(&cfg.EnvFile, "env-file", ".env.test", "path to env file (KEY=VALUE format) with test configuration")
}

// LoadConfig loads the env file pointed to by cfg.EnvFile and populates cfg from env vars.
// Must be called after flag.Parse() runs — i.e., at the start of BeforeSuite.
func LoadConfig() error {
	if err := loadEnvFile(cfg.EnvFile); err != nil {
		return err
	}
	cfg.Kubeconfig = os.Getenv("KUBECONFIG")
	if cfg.Kubeconfig == "" {
		return fmt.Errorf("KUBECONFIG must be set in %q or the process environment", cfg.EnvFile)
	}
	cfg.HostedClusterName = envOrDefault("HOSTED_CLUSTER_NAME", "doca")
	cfg.ClustersNamespace = envOrDefault("CLUSTERS_NAMESPACE", "clusters")
	cfg.DPFNamespace = envOrDefault("DPF_NAMESPACE", "dpf-operator-system")
	cfg.WorkloadNamespace = envOrDefault("SANITY_TESTS_WORKLOAD_NAMESPACE", "workload")
	cfg.DPUClusterName = envOrDefault("DPU_CLUSTER_NAME", "doca")
	cfg.DPUDeploymentName = envOrDefault("DPU_DEPLOYMENT_NAME", "dpudeployment")
	cfg.UpgradeReleaseImage = envOrDefault("UPGRADE_RELEASE_IMAGE", "")
	cfg.NewBFBURL = envOrDefault("NEW_BFB_URL", "")
	cfg.NewBFBFileName = envOrDefault("NEW_BFB_FILENAME", "")
	cfg.NewBFBVersionsBSP = envOrDefault("NEW_BFB_BSP", "")
	cfg.NewBFBVersionsDOCA = envOrDefault("NEW_BFB_DOCA", "")
	cfg.NewBFBVersionsUEFI = envOrDefault("NEW_BFB_UEFI", "")
	cfg.NewBFBVersionsATF = envOrDefault("NEW_BFB_ATF", "")
	cfg.UpgradeMachineOSURL = envOrDefault("UPGRADE_MACHINE_OS_URL", "")
	cfg.PingCount = envOrDefaultInt("SANITY_TESTS_PING_COUNT", 20)
	cfg.PingHBNToHBN = envOrDefaultBool("SANITY_TESTS_PING_HBN_TO_HBN_PODS", false)
	cfg.WorkerCount = envOrDefaultInt("WORKER_COUNT", 0)
	cfg.ExternalRouterIP = envOrDefault("EXTERNAL_ROUTER_IP", "")
	return nil
}

// loadEnvFile reads a KEY=VALUE file and calls os.Setenv for each entry.
// Lines starting with '#' and blank lines are ignored.
// A missing file is not an error — returns nil.
func loadEnvFile(path string) error {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("opening env file %q: %w", path, err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx < 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		value := strings.TrimSpace(line[idx+1:])
		if key != "" {
			if err := os.Setenv(key, value); err != nil {
				return fmt.Errorf("setting %q: %w", key, err)
			}
		}
	}
	return scanner.Err()
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envOrDefaultInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}

func envOrDefaultBool(key string, fallback bool) bool {
	if v := os.Getenv(key); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return fallback
}
