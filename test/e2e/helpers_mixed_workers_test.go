package e2e

import (
	"bytes"
	"context"
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/yaml"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/openshift-dpf/test/manifests"
	"github.com/openshift-dpf/test/utils"
)

func verifyMixedWorkerEastWestConnectivity() {
	By("Creating an isolated namespace for the two mixed-worker ping pods")
	namespace := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{GenerateName: "dpf-mixed-", Labels: map[string]string{"pod-security.kubernetes.io/enforce": "privileged"}}}
	DeferCleanup(func() {
		if namespace.Name == "" {
			return
		}
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		err := mgmtClient.Delete(cleanupCtx, namespace)
		Expect(err == nil || apierrors.IsNotFound(err)).To(BeTrue(), "delete mixed-worker namespace: %v", err)
		Eventually(func() bool {
			return apierrors.IsNotFound(mgmtClient.Get(cleanupCtx, client.ObjectKeyFromObject(namespace), &corev1.Namespace{}))
		}).WithContext(cleanupCtx).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(BeTrue())
	})
	Expect(mgmtClient.Create(ctx, namespace)).To(Succeed())
	Expect(mgmtClient.Create(ctx, &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: "ping", Namespace: namespace.Name}})).To(Succeed())
	binding := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{Name: "ping-scc", Namespace: namespace.Name},
		Subjects:   []rbacv1.Subject{{Kind: "ServiceAccount", Name: "ping", Namespace: namespace.Name}},
		RoleRef:    rbacv1.RoleRef{APIGroup: rbacv1.GroupName, Kind: "ClusterRole", Name: "system:openshift:scc:privileged"},
	}
	Expect(mgmtClient.Create(ctx, binding)).To(Succeed())
	var deployment appsv1.Deployment
	Expect(yaml.NewYAMLOrJSONDecoder(bytes.NewReader(manifests.RegularWorkerWorkloadManifestBytes()), 4096).Decode(&deployment)).To(Succeed())
	regular := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{GenerateName: "regular-", Namespace: namespace.Name}, Spec: *deployment.Spec.Template.Spec.DeepCopy()}
	regular.Spec.TopologySpreadConstraints = nil
	regular.Spec.ServiceAccountName = "ping"
	dpu := regular.DeepCopy()
	dpu.GenerateName = "dpu-"
	dpu.Spec.Affinity = nil
	dpu.Spec.NodeSelector = map[string]string{utils.DPUEnabledLabel: ""}
	Expect(mgmtClient.Create(ctx, regular)).To(Succeed())
	Expect(mgmtClient.Create(ctx, dpu)).To(Succeed())
	By("Waiting for a Ready pod on each worker type")
	for _, pod := range []*corev1.Pod{regular, dpu} {
		Eventually(func(g Gomega) {
			g.Expect(mgmtClient.Get(ctx, client.ObjectKeyFromObject(pod), pod)).To(Succeed())
			g.Expect(podIsReady(pod)).To(BeTrue())
		}).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())
	}
	node := &corev1.Node{}
	Expect(mgmtClient.Get(ctx, client.ObjectKey{Name: regular.Spec.NodeName}, node)).To(Succeed())
	Expect(hasDPUEnabledLabel(*node)).To(BeFalse())
	Expect(node.Labels).NotTo(HaveKey("node-role.kubernetes.io/control-plane"))
	Expect(mgmtClient.Get(ctx, client.ObjectKey{Name: dpu.Spec.NodeName}, node)).To(Succeed())
	Expect(hasDPUEnabledLabel(*node)).To(BeTrue())
	for _, pair := range [][2]*corev1.Pod{{regular, dpu}, {dpu, regular}} {
		By(fmt.Sprintf("Pinging from %s on %s to %s on %s", pair[0].Name, pair[0].Spec.NodeName, pair[1].Name, pair[1].Spec.NodeName))
		Expect(utils.PingFromPod(ctx, mgmtConfig, mgmtClientset, namespace.Name, pair[0].Name, "netshoot", pair[1].Status.PodIP, cfg.PingCount, 0)).To(Succeed())
	}
}
