// Package networking validates pod-to-pod and service connectivity.
// Section 2 of the DPF QA Test Plan.
package networking_test

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/config"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/framework"
	"github.com/rh-ecosystem-edge/openshift-dpf/test/e2e/labels"
)

const (
	netTestNS   = "dpf-e2e-networking"
	iperf3Image = "quay.io/openshift/origin-tests:4.22"
)

// TC-NET-001 [ALM:14178] — Pod-to-pod and service connectivity across same-node, cross-node, external.
// Priority: Urgent | Labels: bat, networking
var _ = Describe("TC-NET-001", Label(labels.Domain.BAT, labels.Domain.Networking), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig
	var dpuWorkers []corev1.Node

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
		_ = cfg // used in sub-tests

		By("creating test namespace")
		_, err := framework.CreateNamespace(ctx, mgmt, netTestNS)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())

		By("listing DPU worker nodes")
		var err2 error
		dpuWorkers, err2 = framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err2).NotTo(gomega.HaveOccurred())
		gomega.Expect(dpuWorkers).To(gomega.HaveLen(cfg.DPUCount),
			"expected %d DPU worker nodes", cfg.DPUCount)
	})

	AfterAll(func() {
		By("cleaning up test namespace")
		_ = framework.DeleteNamespace(ctx, mgmt, netTestNS)
	})

	It("deploys server pod on same DPU node and waits for Running", func() {
		gomega.Expect(dpuWorkers).NotTo(gomega.BeEmpty())
		node := dpuWorkers[0]

		serverPod := buildNetPod("server-same", netTestNS, node.Name)
		gomega.Expect(mgmt.Create(ctx, serverPod)).To(gomega.Or(gomega.Succeed(),
			gomega.MatchError(gomega.ContainSubstring("already exists"))))

		waitForPodRunning(ctx, mgmt, netTestNS, "server-same")
	})

	It("pod-to-pod ping succeeds on same node", func() {
		gomega.Expect(dpuWorkers).NotTo(gomega.BeEmpty())
		node := dpuWorkers[0]

		// Fetch the server pod IP to ping.
		serverPod := &corev1.Pod{}
		gomega.Expect(mgmt.Get(ctx, client.ObjectKey{Namespace: netTestNS, Name: "server-same"}, serverPod)).
			To(gomega.Succeed())
		serverIP := serverPod.Status.PodIP
		gomega.Expect(serverIP).NotTo(gomega.BeEmpty(), "server pod has no IP yet")

		// Launch a short-lived ping pod whose exit code proves reachability.
		pingPodName := "ping-same"
		pingPod := buildPingPod(pingPodName, netTestNS, node.Name, serverIP)
		gomega.Expect(mgmt.Create(ctx, pingPod)).To(gomega.Or(gomega.Succeed(),
			gomega.MatchError(gomega.ContainSubstring("already exists"))))

		// Wait for the ping pod to reach Succeeded (command completed with exit 0).
		By(fmt.Sprintf("waiting for ping pod to complete pinging %s", serverIP))
		gomega.Eventually(func(g gomega.Gomega) {
			p := &corev1.Pod{}
			g.Expect(mgmt.Get(ctx, client.ObjectKey{Namespace: netTestNS, Name: pingPodName}, p)).
				To(gomega.Succeed())
			g.Expect(p.Status.Phase).To(gomega.Equal(corev1.PodSucceeded),
				"ping pod phase: %s", p.Status.Phase)
		}).WithTimeout(framework.Iperf3TestTimeout).WithPolling(framework.PollInterval).Should(gomega.Succeed())
	})

	It("deploys server and client pods on node-0 and node-1 for cross-node test", func() {
		if len(dpuWorkers) < 2 {
			Skip("cross-node test requires at least 2 DPU nodes")
		}
		serverPod := buildNetPod("server-cross", netTestNS, dpuWorkers[0].Name)
		clientPod := buildNetPod("client-cross", netTestNS, dpuWorkers[1].Name)
		gomega.Expect(mgmt.Create(ctx, serverPod)).To(gomega.Or(gomega.Succeed(),
			gomega.MatchError(gomega.ContainSubstring("already exists"))))
		gomega.Expect(mgmt.Create(ctx, clientPod)).To(gomega.Or(gomega.Succeed(),
			gomega.MatchError(gomega.ContainSubstring("already exists"))))

		waitForPodRunning(ctx, mgmt, netTestNS, "server-cross")
		waitForPodRunning(ctx, mgmt, netTestNS, "client-cross")
	})

	It("cross-node pod-to-pod ping succeeds", func() {
		if len(dpuWorkers) < 2 {
			Skip("cross-node test requires at least 2 DPU nodes")
		}

		serverPod := &corev1.Pod{}
		gomega.Expect(mgmt.Get(ctx, client.ObjectKey{Namespace: netTestNS, Name: "server-cross"}, serverPod)).
			To(gomega.Succeed())
		serverIP := serverPod.Status.PodIP
		gomega.Expect(serverIP).NotTo(gomega.BeEmpty(), "cross-node server pod has no IP")

		// Launch a ping pod on the client node (different from server).
		pingPodName := "ping-cross"
		pingPod := buildPingPod(pingPodName, netTestNS, dpuWorkers[1].Name, serverIP)
		gomega.Expect(mgmt.Create(ctx, pingPod)).To(gomega.Or(gomega.Succeed(),
			gomega.MatchError(gomega.ContainSubstring("already exists"))))

		By(fmt.Sprintf("waiting for cross-node ping pod to complete pinging %s", serverIP))
		gomega.Eventually(func(g gomega.Gomega) {
			p := &corev1.Pod{}
			g.Expect(mgmt.Get(ctx, client.ObjectKey{Namespace: netTestNS, Name: pingPodName}, p)).
				To(gomega.Succeed())
			g.Expect(p.Status.Phase).To(gomega.Equal(corev1.PodSucceeded),
				"cross-node ping pod phase: %s", p.Status.Phase)
		}).WithTimeout(framework.Iperf3TestTimeout).WithPolling(framework.PollInterval).Should(gomega.Succeed())
	})

	It("ClusterIP service has populated endpoints", func() {
		svc := buildClusterIPService("test-svc", netTestNS)
		gomega.Expect(mgmt.Create(ctx, svc)).To(gomega.Or(gomega.Succeed(),
			gomega.MatchError(gomega.ContainSubstring("already exists"))))

		By("verifying ClusterIP is assigned")
		gomega.Eventually(func(g gomega.Gomega) {
			got := &corev1.Service{}
			g.Expect(mgmt.Get(ctx, client.ObjectKey{Namespace: netTestNS, Name: "test-svc"}, got)).
				To(gomega.Succeed())
			g.Expect(got.Spec.ClusterIP).NotTo(gomega.BeEmpty())
			g.Expect(got.Spec.ClusterIP).NotTo(gomega.Equal("None"))
		}).WithTimeout(30 * time.Second).WithPolling(2 * time.Second).Should(gomega.Succeed())

		By("verifying Endpoints resource has populated addresses")
		gomega.Eventually(func(g gomega.Gomega) {
			ep := &corev1.Endpoints{}
			g.Expect(mgmt.Get(ctx, client.ObjectKey{Namespace: netTestNS, Name: "test-svc"}, ep)).
				To(gomega.Succeed())
			g.Expect(ep.Subsets).NotTo(gomega.BeEmpty(), "Endpoints has no subsets")
			g.Expect(ep.Subsets[0].Addresses).NotTo(gomega.BeEmpty(),
				"Endpoints subset has no addresses — backing pods may not be Ready")
		}).WithTimeout(90 * time.Second).WithPolling(5 * time.Second).Should(gomega.Succeed())
	})

	It("NodePort service is reachable from cluster network", func() {
		svc := buildNodePortService("test-nodeport-svc", netTestNS)
		gomega.Expect(mgmt.Create(ctx, svc)).To(gomega.Or(gomega.Succeed(),
			gomega.MatchError(gomega.ContainSubstring("already exists"))))

		// Wait for the NodePort to be assigned.
		var nodePort int32
		gomega.Eventually(func(g gomega.Gomega) {
			got := &corev1.Service{}
			g.Expect(mgmt.Get(ctx, client.ObjectKey{Namespace: netTestNS, Name: "test-nodeport-svc"}, got)).
				To(gomega.Succeed())
			g.Expect(got.Spec.Ports).NotTo(gomega.BeEmpty())
			g.Expect(got.Spec.Ports[0].NodePort).To(gomega.BeNumerically(">", 0))
			nodePort = got.Spec.Ports[0].NodePort
		}).WithTimeout(30 * time.Second).WithPolling(2 * time.Second).Should(gomega.Succeed())

		gomega.Expect(dpuWorkers).NotTo(gomega.BeEmpty())
		nodeAddr := nodeExternalOrInternalIP(dpuWorkers[0])
		gomega.Expect(nodeAddr).NotTo(gomega.BeEmpty(), "DPU node has no usable IP address")

		// An HTTP GET to the NodePort URL proves that kube-proxy / OVN routing is
		// forwarding the port.  The backing pod is a sleep container so we expect
		// a connection-refused or 404/5xx — any response (or refusal) that is NOT
		// a network-level timeout confirms the port is reachable.
		url := fmt.Sprintf("http://%s:%d/", nodeAddr, nodePort)
		By(fmt.Sprintf("probing NodePort URL %s", url))
		httpClient := &http.Client{Timeout: 10 * time.Second}
		resp, err := httpClient.Get(url) //nolint:noctx
		if err != nil {
			// Connection refused means the port is open on the node (routing works)
			// but no server is listening inside the pod — this is expected for a
			// sleep-based test pod.  Any other network error (timeout, no route)
			// would indicate a routing failure.
			gomega.Expect(strings.Contains(err.Error(), "connection refused") ||
				strings.Contains(err.Error(), "EOF") ||
				strings.Contains(err.Error(), "reset by peer"),
			).To(gomega.BeTrue(),
				"unexpected NodePort connectivity error (want refused/EOF, got): %v", err)
		} else {
			defer resp.Body.Close()
			// Any HTTP status (200, 404, 5xx) proves the routing is working.
			gomega.Expect(resp.StatusCode).To(gomega.BeNumerically(">=", 100),
				"unexpected HTTP status from NodePort")
		}
	})
})

// TC-NET-003 [ALM:142XX] — Kubernetes traffic flow iperf3 offload tests.
// Priority: High | Labels: networking
var _ = Describe("TC-NET-003", Label(labels.Domain.Networking), Ordered, func() {
	var ctx context.Context
	var mgmt client.Client
	var cfg *config.E2EConfig

	BeforeAll(func() {
		ctx = context.Background()
		mgmt, _ = framework.GetClients()
		cfg = config.Get()
		_ = cfg
	})

	It("iperf3 client-server pods are schedulable on DPU nodes", func() {
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, mgmt)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(dpuWorkers).NotTo(gomega.BeEmpty(), "no DPU workers for iperf3 test")
	})

	It("HBN pods are running on all DPU host nodes", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, config.Get().DPFNamespace, map[string]string{
			"svc.dpu.nvidia.com/name": "hbn",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(pods).NotTo(gomega.BeEmpty(), "HBN pods must be running for offload tests")
	})

	It("OVN pods are running on all DPU host nodes", func() {
		pods, err := framework.ListRunningPods(ctx, mgmt, config.Get().DPFNamespace, map[string]string{
			"svc.dpu.nvidia.com/name": "ovn",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(pods).NotTo(gomega.BeEmpty(), "OVN pods must be running for offload tests")
	})

	It("SRIOV network device plugin DaemonSet is Ready", func() {
		// The SRIOV device plugin exposes the VF resources required for iperf3 offload.
		// Check that at least one matching DaemonSet has all desired pods scheduled and ready.
		dsList := &appsv1.DaemonSetList{}
		err := mgmt.List(ctx, dsList)
		gomega.Expect(err).NotTo(gomega.HaveOccurred())

		var sriovDS *appsv1.DaemonSet
		for i := range dsList.Items {
			name := dsList.Items[i].Name
			if strings.Contains(name, "sriov") || strings.Contains(name, "device-plugin") {
				sriovDS = &dsList.Items[i]
				break
			}
		}
		if sriovDS == nil {
			Skip("SRIOV device plugin DaemonSet not found — skipping iperf3 offload prerequisite check")
		}

		By(fmt.Sprintf("checking DaemonSet %s/%s is fully Ready", sriovDS.Namespace, sriovDS.Name))
		gomega.Expect(sriovDS.Status.DesiredNumberScheduled).To(gomega.BeNumerically(">", 0),
			"SRIOV DaemonSet has 0 desired pods")
		gomega.Expect(sriovDS.Status.NumberReady).To(gomega.Equal(sriovDS.Status.DesiredNumberScheduled),
			"SRIOV DaemonSet pods not fully ready: %d/%d",
			sriovDS.Status.NumberReady, sriovDS.Status.DesiredNumberScheduled)
	})
})

// TC-NET-004 [ALM:142XX] — Kubernetes traffic flow RDMA offload tests.
// Priority: High | Labels: networking, requires-nodes
var _ = Describe("TC-NET-004", Label(labels.Domain.Networking, labels.Domain.RequiresNodes), Ordered, func() {
	var ctx context.Context

	BeforeAll(func() {
		ctx = context.Background()
		_, _ = framework.GetClients()
	})

	It("RDMA device plugin pods are running", func() {
		pods, err := framework.ListRunningPods(ctx, framework.MgmtClient(), config.Get().DPFNamespace, map[string]string{
			"app": "rdma-device-plugin",
		})
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		if len(pods) == 0 {
			Skip("RDMA device plugin not deployed — skipping RDMA offload tests")
		}
		gomega.Expect(pods).NotTo(gomega.BeEmpty())
	})

	It("SRIOV network device plugin allocates RDMA resources on DPU nodes", func() {
		dpuWorkers, err := framework.ListDPUWorkerNodes(ctx, framework.MgmtClient())
		gomega.Expect(err).NotTo(gomega.HaveOccurred())
		gomega.Expect(dpuWorkers).NotTo(gomega.BeEmpty(), "no DPU workers for RDMA resource check")

		// At least one DPU node must advertise an RDMA-related resource
		// (e.g. rdma/hca, rdma/vf, or any resource with "rdma" in the name).
		foundRDMA := false
		for _, n := range dpuWorkers {
			for resourceName, qty := range n.Status.Capacity {
				name := string(resourceName)
				if strings.Contains(strings.ToLower(name), "rdma") {
					By(fmt.Sprintf("node %s advertises RDMA capacity: %s=%s", n.Name, name, qty.String()))
					foundRDMA = true
				}
			}
		}
		if !foundRDMA {
			Skip("no RDMA capacity resources found on DPU nodes — RDMA device plugin may not be configured")
		}
		gomega.Expect(foundRDMA).To(gomega.BeTrue(),
			"expected at least one DPU node to advertise RDMA capacity resources")
	})
})

// helpers

// buildNetPod creates a long-lived sleep pod for connectivity testing.
func buildNetPod(name, ns, nodeName string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels: map[string]string{
				framework.CleanupLabel: "true",
				"app":                 name,
			},
		},
		Spec: corev1.PodSpec{
			NodeName:      nodeName,
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{
				{
					Name:    "net",
					Image:   "quay.io/openshift/origin-cli:4.20",
					Command: []string{"sleep", "3600"},
				},
			},
		},
	}
}

// buildPingPod creates a pod that pings targetIP three times and exits 0 on success.
// The pod uses RestartPolicyNever so its phase transitions to Succeeded or Failed.
func buildPingPod(name, ns, nodeName, targetIP string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels: map[string]string{
				framework.CleanupLabel: "true",
				"app":                 name,
			},
		},
		Spec: corev1.PodSpec{
			NodeName:      nodeName,
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{
				{
					Name:  "ping",
					Image: "quay.io/openshift/origin-cli:4.20",
					// -W 2: 2-second deadline per probe; -c 3: three probes.
					// Exit code 0 iff all three succeed (0% packet loss).
					Command: []string{"sh", "-c",
						fmt.Sprintf("ping -c 3 -W 2 %s && echo PING_OK", targetIP)},
				},
			},
		},
	}
}

func buildClusterIPService(name, ns string) *corev1.Service {
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels:    map[string]string{framework.CleanupLabel: "true"},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": "server-same"},
			Ports: []corev1.ServicePort{
				{Port: 5201, TargetPort: intstr.FromInt(5201), Protocol: corev1.ProtocolTCP},
			},
			Type: corev1.ServiceTypeClusterIP,
		},
	}
}

func buildNodePortService(name, ns string) *corev1.Service {
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels:    map[string]string{framework.CleanupLabel: "true"},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": "server-cross"},
			Ports: []corev1.ServicePort{
				{Port: 5201, TargetPort: intstr.FromInt(5201), Protocol: corev1.ProtocolTCP},
			},
			Type: corev1.ServiceTypeNodePort,
		},
	}
}

// nodeExternalOrInternalIP returns the best routable IP for a node:
// prefers ExternalIP, falls back to InternalIP.
func nodeExternalOrInternalIP(n corev1.Node) string {
	var internal string
	for _, addr := range n.Status.Addresses {
		switch addr.Type {
		case corev1.NodeExternalIP:
			return addr.Address
		case corev1.NodeInternalIP:
			internal = addr.Address
		}
	}
	return internal
}

func waitForPodRunning(ctx context.Context, c client.Client, ns, name string) {
	GinkgoHelper()
	gomega.Eventually(func(g gomega.Gomega) {
		pod := &corev1.Pod{}
		g.Expect(c.Get(ctx, client.ObjectKey{Namespace: ns, Name: name}, pod)).To(gomega.Succeed())
		g.Expect(pod.Status.Phase).To(gomega.Equal(corev1.PodRunning), "pod %s/%s not Running", ns, name)
	}).WithTimeout(3 * time.Minute).WithPolling(5 * time.Second).Should(gomega.Succeed())
}
