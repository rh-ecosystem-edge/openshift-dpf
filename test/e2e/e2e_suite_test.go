package e2e

import (
	"context"
	"fmt"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"

	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
	"github.com/openshift-dpf/test/utils"
)

var (
	ctx context.Context

	mgmtClient    client.Client
	mgmtClientset *kubernetes.Clientset
	mgmtConfig    *rest.Config

	hostedClient    client.Client
	hostedClientset *kubernetes.Clientset
	hostedConfig    *rest.Config

	dpuHostWorkers []corev1.Node
	dpuWorkers     []corev1.Node
)

func TestE2E(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "DPF E2E Suite")
}

var _ = BeforeSuite(func() {
	ctx = context.Background()

	By("Creating management cluster clients")
	mgmt, err := utils.NewClusterClients(cfg.Kubeconfig)
	Expect(err).NotTo(HaveOccurred(), "failed to create management cluster clients")
	mgmtClient = mgmt.Client
	mgmtClientset = mgmt.Clientset
	mgmtConfig = mgmt.Config

	By("Extracting hosted cluster kubeconfig")
	secretName := fmt.Sprintf("%s-admin-kubeconfig", cfg.HostedClusterName)
	kubeconfigBytes, err := utils.ExtractHostedKubeconfig(ctx, mgmtClient, cfg.ClustersNamespace, secretName)
	Expect(err).NotTo(HaveOccurred(), "failed to extract hosted cluster kubeconfig")

	By("Creating hosted cluster clients")
	hosted, err := utils.NewClusterClientsFromBytes(kubeconfigBytes)
	Expect(err).NotTo(HaveOccurred(), "failed to create hosted cluster clients")
	hostedClient = hosted.Client
	hostedClientset = hosted.Clientset
	hostedConfig = hosted.Config

	By("Wiring upstream doca-platform test globals")
	dpfe2e.Ctx = ctx
	dpfe2e.TestClient = mgmtClient
	dpfe2e.RestConfig = mgmtConfig
	dpfe2e.Clientset = mgmtClientset

	By("Discovering DPU-enabled host worker nodes")
	dpuHostWorkers, err = utils.GetDPUEnabledNodes(ctx, mgmtClient)
	Expect(err).NotTo(HaveOccurred())
	GinkgoWriter.Printf("Found %d DPU-enabled host worker nodes\n", len(dpuHostWorkers))
	for _, n := range dpuHostWorkers {
		GinkgoWriter.Printf("  - %s\n", n.Name)
	}

	By("Discovering DPU worker nodes in hosted cluster")
	dpuWorkers, err = utils.GetReadyWorkerNodes(ctx, hostedClient)
	Expect(err).NotTo(HaveOccurred())
	GinkgoWriter.Printf("Found %d DPU worker nodes in hosted cluster\n", len(dpuWorkers))
	for _, n := range dpuWorkers {
		GinkgoWriter.Printf("  - %s\n", n.Name)
	}
})

var _ = AfterSuite(func() {
	// Cleanup is intentionally minimal — we don't delete the workload namespace
	// by default to allow inspection after test runs. Use -cleanup flag or manual
	// deletion if needed.
})
