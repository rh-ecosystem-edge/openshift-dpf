package framework

import (
	"context"
	"encoding/base64"
	"fmt"

	dpfoperatorv1 "github.com/nvidia/doca-platform/api/operator/v1alpha1"
	dpfprovisioningv1 "github.com/nvidia/doca-platform/api/provisioning/v1alpha1"
	dpfservicev1 "github.com/nvidia/doca-platform/api/dpuservice/v1alpha1"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
)

var (
	mgmtClient   client.Client
	hostedClient client.Client
)

// buildScheme returns a runtime.Scheme with all DPF CRD groups registered.
func buildScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = corev1.AddToScheme(s)
	_ = dpfoperatorv1.AddToScheme(s)
	_ = dpfprovisioningv1.AddToScheme(s)
	_ = dpfservicev1.AddToScheme(s)
	return s
}

// InitClients builds the management and hosted cluster clients.
// Called once from BeforeSuite.
func InitClients(mgmtKubeconfig, hostedClusterNS, hostedClusterName string) error {
	scheme := buildScheme()

	restCfg, err := clientcmd.BuildConfigFromFlags("", mgmtKubeconfig)
	if err != nil {
		return fmt.Errorf("build mgmt rest config: %w", err)
	}
	mgmtClient, err = client.New(restCfg, client.Options{Scheme: scheme})
	if err != nil {
		return fmt.Errorf("build mgmt client: %w", err)
	}

	// Extract HyperShift admin kubeconfig from Secret
	hostedCfg, err := hostedClusterRestConfig(context.Background(), mgmtClient, hostedClusterNS, hostedClusterName, scheme)
	if err != nil {
		return fmt.Errorf("build hosted client: %w", err)
	}
	hostedClient, err = client.New(hostedCfg, client.Options{Scheme: scheme})
	if err != nil {
		return fmt.Errorf("build hosted client: %w", err)
	}
	return nil
}

// SetupSuite initialises clients from config. Call from SynchronizedBeforeSuite node 1.
// Safe to call when MgmtKubeconfig is empty (skips client init, tests will skip or fail naturally).
func SetupSuite() {
	cfg := config.LoadOrDefault()
	if cfg.MgmtKubeconfig == "" {
		return
	}
	if err := InitClients(cfg.MgmtKubeconfig, cfg.HostedClusterNamespace, cfg.HostedClusterName); err != nil {
		panic("framework.SetupSuite: " + err.Error())
	}
}

// GetClients returns the initialised management and hosted cluster clients.
func GetClients() (client.Client, client.Client) {
	return mgmtClient, hostedClient
}

// MgmtClient returns the management cluster client.
func MgmtClient() client.Client { return mgmtClient }

// HostedClient returns the hosted (DPU) cluster client.
func HostedClient() client.Client { return hostedClient }

// hostedClusterRestConfig extracts the admin kubeconfig from the HyperShift
// admin-kubeconfig Secret created by the HostedCluster reconciler.
func hostedClusterRestConfig(ctx context.Context, c client.Client, ns, name string, _ *runtime.Scheme) (*rest.Config, error) {
	secret := &corev1.Secret{}
	key := types.NamespacedName{
		Namespace: ns,
		Name:      fmt.Sprintf("%s-admin-kubeconfig", name),
	}
	if err := c.Get(ctx, key, secret); err != nil {
		return nil, fmt.Errorf("get admin-kubeconfig secret %s: %w", key, err)
	}
	raw, ok := secret.Data["kubeconfig"]
	if !ok {
		// Some versions base64-encode it twice
		raw, ok = secret.Data["value"]
		if !ok {
			return nil, fmt.Errorf("admin-kubeconfig secret %s has no 'kubeconfig' key", key)
		}
		decoded, err := base64.StdEncoding.DecodeString(string(raw))
		if err != nil {
			return nil, fmt.Errorf("decode kubeconfig: %w", err)
		}
		raw = decoded
	}
	cfg, err := clientcmd.RESTConfigFromKubeConfig(raw)
	if err != nil {
		return nil, fmt.Errorf("parse hosted kubeconfig: %w", err)
	}
	return cfg, nil
}
