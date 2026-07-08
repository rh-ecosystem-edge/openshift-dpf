package utils

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type ClusterClients struct {
	Client    client.Client
	Clientset *kubernetes.Clientset
	Config    *rest.Config
}

func NewScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(s)
	return s
}

func NewClusterClients(kubeconfigPath string) (*ClusterClients, error) {
	cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	if err != nil {
		return nil, fmt.Errorf("building kubeconfig from %s: %w", kubeconfigPath, err)
	}
	return newClusterClientsFromConfig(cfg)
}

func NewClusterClientsFromBytes(kubeconfigBytes []byte) (*ClusterClients, error) {
	cfg, err := clientcmd.RESTConfigFromKubeConfig(kubeconfigBytes)
	if err != nil {
		return nil, fmt.Errorf("building REST config from kubeconfig bytes: %w", err)
	}
	return newClusterClientsFromConfig(cfg)
}

func newClusterClientsFromConfig(cfg *rest.Config) (*ClusterClients, error) {
	scheme := NewScheme()
	c, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		return nil, fmt.Errorf("creating controller-runtime client: %w", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("creating kubernetes clientset: %w", err)
	}
	return &ClusterClients{Client: c, Clientset: cs, Config: cfg}, nil
}

func ExtractHostedKubeconfig(ctx context.Context, mgmtClient client.Client, namespace, secretName string) ([]byte, error) {
	secret := &corev1.Secret{}
	key := types.NamespacedName{Namespace: namespace, Name: secretName}
	if err := mgmtClient.Get(ctx, key, secret); err != nil {
		return nil, fmt.Errorf("getting hosted kubeconfig secret %s/%s: %w", namespace, secretName, err)
	}
	kubeconfig, ok := secret.Data["kubeconfig"]
	if !ok {
		return nil, fmt.Errorf("secret %s/%s does not contain 'kubeconfig' key", namespace, secretName)
	}
	return kubeconfig, nil
}
