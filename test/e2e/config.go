package e2e

import (
	"flag"
	"os"
	"strconv"
)

type TestConfig struct {
	Kubeconfig        string
	HostedClusterName string
	ClustersNamespace string
	DPFNamespace      string
	WorkloadNamespace string
	DPUClusterName    string
	DPUDeploymentName string
	PingCount         int
	PingHBNToHBN      bool
	WorkerCount       int
}

var cfg TestConfig

func init() {
	flag.StringVar(&cfg.Kubeconfig, "e2e.kubeconfig", envOrDefault("KUBECONFIG", "./kubeconfig"), "path to management cluster kubeconfig")
	flag.StringVar(&cfg.HostedClusterName, "hosted-cluster-name", envOrDefault("HOSTED_CLUSTER_NAME", "doca"), "hosted cluster name")
	flag.StringVar(&cfg.ClustersNamespace, "clusters-namespace", envOrDefault("CLUSTERS_NAMESPACE", "clusters"), "namespace for hosted clusters")
	flag.StringVar(&cfg.DPFNamespace, "dpf-namespace", envOrDefault("DPF_NAMESPACE", "dpf-operator-system"), "DPF operator namespace")
	flag.StringVar(&cfg.WorkloadNamespace, "workload-namespace", envOrDefault("SANITY_TESTS_WORKLOAD_NAMESPACE", "workload"), "workload test namespace")
	flag.StringVar(&cfg.DPUClusterName, "dpu-cluster-name", envOrDefault("DPU_CLUSTER_NAME", "doca"), "DPU cluster name (used for ignition ConfigMap naming)")
	flag.StringVar(&cfg.DPUDeploymentName, "dpu-deployment-name", envOrDefault("DPU_DEPLOYMENT_NAME", "dpudeployment"), "DPUDeployment name in the DPF namespace")
	flag.IntVar(&cfg.PingCount, "ping-count", envOrDefaultInt("SANITY_TESTS_PING_COUNT", 20), "ping count for connectivity tests")
	flag.BoolVar(&cfg.PingHBNToHBN, "ping-hbn-to-hbn", envOrDefaultBool("SANITY_TESTS_PING_HBN_TO_HBN_PODS", false), "enable HBN-to-HBN pod ping tests")
	flag.IntVar(&cfg.WorkerCount, "worker-count", envOrDefaultInt("WORKER_COUNT", 0), "expected number of DPU worker nodes")
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
