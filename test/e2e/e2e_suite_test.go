package e2e

import (
	"context"
	"fmt"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	dpuservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"
	operatorv1 "github.com/nvidia/doca-platform/api/operator/v1alpha1"
	dpfe2e "github.com/nvidia/doca-platform/test/e2e"
	"github.com/nvidia/doca-platform/test/e2e/cleanup"
	dpftestutils "github.com/nvidia/doca-platform/test/utils"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"

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

	// dpfInput is the upstream SystemTestInput populated from the live cluster.
	dpfInput *dpfe2e.SystemTestInput
)

func init() {
	dpfe2e.CleanupFlags = cleanup.NewCleanupFlagsFromCLI()
}

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

	By("Initializing cleanup tracker")
	dpfe2e.CleanupFlags.Init()
	resourcesToDelete := []client.ObjectList{
		&dpuservicev1.DPUDeploymentList{},
		&dpuservicev1.DPUServiceList{},
		&dpuservicev1.DPUServiceChainList{},
		&dpuservicev1.DPUServiceInterfaceList{},
		&dpuservicev1.DPUServiceIPAMList{},
		&dpuservicev1.DPUServiceTemplateList{},
		&dpuservicev1.DPUServiceConfigurationList{},
	}
	dpfe2e.CleanupTracker = cleanup.NewTracker(
		dpftestutils.CleanupWithLabelAndWait,
		dpfe2e.CleanupFlags,
		ctx, mgmtClient, resourcesToDelete,
	)

	By("Constructing SystemTestInput from live cluster")
	dpfInput = buildSystemTestInputFromCluster(ctx, mgmtClient, mgmtConfig)

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

	dpfInput.NumberOfDPUNodes = len(dpuHostWorkers)
	GinkgoWriter.Printf("SystemTestInput ready: %d DPU nodes\n", dpfInput.NumberOfDPUNodes)
})

// buildSystemTestInputFromCluster reads the existing DPF resources from the live
// management cluster and constructs a SystemTestInput suitable for upstream Validate*
// functions. This avoids needing config YAML files since DPF is already deployed.
func buildSystemTestInputFromCluster(ctx context.Context, c client.Client, restCfg *rest.Config) *dpfe2e.SystemTestInput {
	input := &dpfe2e.SystemTestInput{
		Namespace:       dpfe2e.DPFOperatorSystemNamespace,
		Client:          c,
		RestConfig:      restCfg,
		NumberOfDPUsPerNode: 1,
	}

	By("Reading DPFOperatorConfig from cluster")
	dpfConfig := &operatorv1.DPFOperatorConfig{}
	Eventually(func(g Gomega) {
		g.Expect(c.Get(ctx, client.ObjectKey{
			Namespace: dpfe2e.DPFOperatorSystemNamespace,
			Name:      dpfe2e.ConfigName,
		}, dpfConfig)).To(Succeed())
	}).WithTimeout(30 * time.Second).WithPolling(1 * time.Second).Should(Succeed())
	input.Config = dpfConfig

	By("Reading DPUDeployment from cluster")
	dpuDeploymentList := &dpuservicev1.DPUDeploymentList{}
	err := c.List(ctx, dpuDeploymentList, client.InNamespace(dpfe2e.DPFOperatorSystemNamespace))
	if err == nil && len(dpuDeploymentList.Items) > 0 {
		input.DPUDeployment = &dpuDeploymentList.Items[0]
		GinkgoWriter.Printf("Found DPUDeployment: %s\n", input.DPUDeployment.Name)
	}

	By("Reading DPUServiceChains from cluster")
	dpuServiceChainList := &dpuservicev1.DPUServiceChainList{}
	err = c.List(ctx, dpuServiceChainList, client.InNamespace(dpfe2e.DPFOperatorSystemNamespace))
	if err == nil && len(dpuServiceChainList.Items) > 0 {
		input.DPUServiceChain = &dpuServiceChainList.Items[0]
		GinkgoWriter.Printf("Found DPUServiceChain: %s\n", input.DPUServiceChain.Name)
	}

	By("Reading DPUServiceInterfaces from cluster")
	dpuServiceInterfaceList := &dpuservicev1.DPUServiceInterfaceList{}
	err = c.List(ctx, dpuServiceInterfaceList, client.InNamespace(dpfe2e.DPFOperatorSystemNamespace))
	if err == nil && len(dpuServiceInterfaceList.Items) > 0 {
		input.DPUServiceInterface = &dpuServiceInterfaceList.Items[0]
		GinkgoWriter.Printf("Found DPUServiceInterface: %s\n", input.DPUServiceInterface.Name)
	}

	By("Reading DPUServiceIPAMs from cluster")
	dpuServiceIPAMList := &dpuservicev1.DPUServiceIPAMList{}
	err = c.List(ctx, dpuServiceIPAMList, client.InNamespace(dpfe2e.DPFOperatorSystemNamespace))
	if err == nil && len(dpuServiceIPAMList.Items) > 0 {
		for i := range dpuServiceIPAMList.Items {
			ipam := &dpuServiceIPAMList.Items[i]
			if input.IPPoolDPUServiceIPAM == nil {
				input.IPPoolDPUServiceIPAM = ipam
			}
			GinkgoWriter.Printf("Found DPUServiceIPAM: %s\n", ipam.Name)
		}
	}

	return input
}

var _ = ReportBeforeEach(func(spec SpecReport) {
	if dpfe2e.CleanupTracker != nil {
		dpfe2e.CleanupTracker.HandleScopeLifecycle(&spec, cleanup.GinkgoHook.BeforeEach)
	}
})

var _ = ReportAfterEach(func(spec SpecReport) {
	if dpfe2e.CleanupTracker != nil {
		dpfe2e.CleanupTracker.HandleScopeLifecycle(&spec, cleanup.GinkgoHook.AfterEach)
	}
})

var _ = AfterSuite(func() {
	if dpfe2e.CleanupTracker != nil {
		By("Performing final suite cleanup")
		dpfe2e.CleanupTracker.HandleScopeLifecycle(nil, cleanup.GinkgoHook.AfterSuite)
	}
})
