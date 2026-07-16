package config

import (
	"os"

	"sigs.k8s.io/yaml"
)

// E2EConfig holds environment-specific parameters read from a YAML file or env vars.
// Pointer fields are optional: nil means the corresponding tests are skipped.
type E2EConfig struct {
	// MgmtKubeconfig is the path to the management cluster kubeconfig.
	// Falls back to KUBECONFIG env var if empty.
	MgmtKubeconfig string `json:"mgmtKubeconfig"`

	// HostedClusterName is the name of the HyperShift HostedCluster.
	HostedClusterName string `json:"hostedClusterName"`

	// HostedClusterNamespace is the namespace of the HyperShift HostedCluster.
	HostedClusterNamespace string `json:"hostedClusterNamespace"`

	// DPFNamespace is the namespace where DPF operator is deployed (default: dpf-operator-system).
	DPFNamespace string `json:"dpfNamespace"`

	// DPUCount is the expected number of DPU nodes in the cluster.
	DPUCount int `json:"dpuCount"`

	// HyperviserHost is the SSH address of the hypervisor that hosts the cluster VMs.
	// Required for SSH-based tests (reboot, IPMI).
	HypervisorHost *string `json:"hypervisorHost,omitempty"`

	// HypervisorUser is the SSH user for the hypervisor.
	HypervisorUser *string `json:"hypervisorUser,omitempty"`

	// SSHPrivateKeyPath is the path to the SSH private key used to connect to worker nodes.
	SSHPrivateKeyPath *string `json:"sshPrivateKeyPath,omitempty"`

	// BMCAddresses maps DPU host node names to their BMC (Redfish/IPMI) addresses.
	// Required for BMC-driven tests (TC-RES-003, TC-RES-004, TC-RES-005).
	BMCAddresses map[string]string `json:"bmcAddresses,omitempty"`

	// BMCUser is the BMC username (required when BMCAddresses is set).
	BMCUser *string `json:"bmcUser,omitempty"`

	// BMCPassword is the BMC password (required when BMCAddresses is set).
	BMCPassword *string `json:"bmcPassword,omitempty"`

	// PreviousDPFVersion is the DPF version to upgrade from in upgrade tests.
	PreviousDPFVersion *string `json:"previousDPFVersion,omitempty"`

	// DPFVersion is the current/target DPF version.
	DPFVersion string `json:"dpfVersion"`
}

var cfg *E2EConfig

// Load reads the YAML config from path and overlays env var overrides.
// Panics on parse errors so misconfiguration is caught at suite startup.
func Load(path string) *E2EConfig {
	data, err := os.ReadFile(path)
	if err != nil {
		panic("e2e config: " + err.Error())
	}
	c := &E2EConfig{}
	if err := yaml.UnmarshalStrict(data, c); err != nil {
		panic("e2e config parse: " + err.Error())
	}
	// Allow env var override for kubeconfig
	if c.MgmtKubeconfig == "" {
		c.MgmtKubeconfig = os.Getenv("KUBECONFIG")
	}
	if c.HostedClusterName == "" {
		c.HostedClusterName = os.Getenv("HOSTED_CLUSTER_NAME")
	}
	if c.HostedClusterNamespace == "" {
		c.HostedClusterNamespace = os.Getenv("HOSTED_CLUSTER_NAMESPACE")
	}
	if c.DPFNamespace == "" {
		c.DPFNamespace = "dpf-operator-system"
	}
	cfg = c
	return c
}

// Get returns the loaded config, auto-loading from E2E_CONFIG_FILE env var if not yet loaded.
func Get() *E2EConfig {
	if cfg == nil {
		return LoadOrDefault()
	}
	return cfg
}

// LoadOrDefault loads config from E2E_CONFIG_FILE env var, or falls back to pure env-var config.
func LoadOrDefault() *E2EConfig {
	if cfg != nil {
		return cfg
	}
	if path := os.Getenv("E2E_CONFIG_FILE"); path != "" {
		return Load(path)
	}
	// No config file: build a minimal config from env vars
	c := &E2EConfig{
		MgmtKubeconfig:         os.Getenv("KUBECONFIG"),
		HostedClusterName:      os.Getenv("HOSTED_CLUSTER_NAME"),
		HostedClusterNamespace: os.Getenv("HOSTED_CLUSTER_NAMESPACE"),
		DPFNamespace:           "dpf-operator-system",
		DPUCount:               2,
	}
	if ns := os.Getenv("DPF_NAMESPACE"); ns != "" {
		c.DPFNamespace = ns
	}
	cfg = c
	return c
}
