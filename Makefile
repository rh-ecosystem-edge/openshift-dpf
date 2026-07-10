# Include environment variables (skip for targets that don't need a .env)
ifeq ($(filter generate-env validate-env-files help,$(MAKECMDGOALS)),)
include .env
export
endif

# Script paths
CLUSTER_SCRIPT := scripts/cluster.sh
MANIFESTS_SCRIPT := scripts/manifests.sh
TOOLS_SCRIPT := scripts/tools.sh
DPF_SCRIPT := scripts/dpf.sh
VM_SCRIPT := scripts/vm.sh
UTILS_SCRIPT := scripts/utils.sh
POST_INSTALL_SCRIPT := scripts/post-install.sh
VERIFY_SCRIPT := scripts/verify.sh
ENV_SCRIPT := scripts/env.sh

# Sanity tests script:
SANITY_CHECKS_SCRIPT := scripts/dpf-sanity-checks.sh

# Traffic flow tests script
TFT_SCRIPT := scripts/traffic-flow-tests.sh

# Worker provisioning script
WORKER_SCRIPT := scripts/worker.sh

.PHONY: all
all:
	@mkdir -p logs
	@bash -o pipefail -c '$(MAKE) _all 2>&1 | tee "logs/make_all_$(shell date +%Y%m%d_%H%M%S).log"'

.PHONY: _all
_all: verify-files check-cluster create-vms prepare-manifests cluster-install update-etc-hosts kubeconfig add-worker-nodes deploy-dpf prepare-dpu-files deploy-dpu-services enable-ovn-injector deploy-observability
	@echo ""
	@echo "================================================================================"
	@echo "✅ DPF Installation Complete!"
	@echo "================================================================================"
	@$(VERIFY_SCRIPT) verify-deployment

.PHONY: verify-files
verify-files:
	@$(UTILS_SCRIPT) verify-files

.PHONY: clean
clean:
	@$(CLUSTER_SCRIPT) clean

.PHONY: aicli-list
aicli-list:
	@bash -c 'source scripts/env.sh && aicli list clusters'
	
.PHONY: delete-cluster
delete-cluster:
	@$(CLUSTER_SCRIPT) delete-cluster

.PHONY: check-cluster
check-cluster:
	@$(CLUSTER_SCRIPT) check-create-cluster

.PHONY: create-cluster
create-cluster:
	@$(CLUSTER_SCRIPT) check-create-cluster

.PHONY: create-day2-cluster
create-day2-cluster:
	@$(CLUSTER_SCRIPT) create-day2-cluster

.PHONY: get-day2-iso
get-day2-iso: create-day2-cluster
	@$(CLUSTER_SCRIPT) get-day2-iso

.PHONY: prepare-manifests
prepare-manifests:
	@$(MANIFESTS_SCRIPT) prepare-manifests

.PHONY: generate-ovn
generate-ovn:
	@$(MANIFESTS_SCRIPT) generate-ovn-manifests

.PHONY: update-paths
update-paths:
	@$(MANIFESTS_SCRIPT) prepare-manifests

.PHONY: download-iso
download-iso:
	@$(CLUSTER_SCRIPT) download-iso

.PHONY: create-vms
create-vms: download-iso
	@$(VM_SCRIPT) create

.PHONY: delete-vms
delete-vms:
	@$(VM_SCRIPT) delete


.PHONY: download-day2-iso
download-day2-iso: create-day2-cluster
	@$(CLUSTER_SCRIPT) download-day2-iso

.PHONY: create-worker-vms
create-worker-vms: download-day2-iso
	@$(VM_SCRIPT) create-worker-vms

.PHONY: delete-worker-vms
delete-worker-vms:
	@$(VM_SCRIPT) delete-worker-vms

.PHONY: add-vm-workers
add-vm-workers:
	@if [ "$(VM_WORKER_COUNT)" = "0" ] || [ -z "$(VM_WORKER_COUNT)" ]; then \
		echo "VM_WORKER_COUNT=0, skipping VM worker provisioning"; \
	else \
		$(MAKE) create-worker-vms; \
		echo "================================================================================"; \
		echo "Adding VM worker nodes via Assisted Installer day2 flow..."; \
		echo "================================================================================"; \
		$(CLUSTER_SCRIPT) install-day2-hosts; \
		if [ "$(AUTO_APPROVE_WORKER_CSR)" = "true" ]; then \
			echo ""; \
			echo "AUTO_APPROVE_WORKER_CSR=true - Deploying CSR auto-approver CronJob..."; \
			$(WORKER_SCRIPT) deploy-csr-auto-approver; \
		else \
			echo ""; \
			$(WORKER_SCRIPT) display-manual-csr-instructions; \
		fi; \
		echo ""; \
		echo "================================================================================"; \
		echo "VM worker node provisioning complete!"; \
		echo "Run 'make worker-status' to verify nodes joined the cluster."; \
		echo "================================================================================"; \
	fi

.PHONY: install-day2-hosts
install-day2-hosts:
	@$(CLUSTER_SCRIPT) install-day2-hosts

.PHONY: cluster-start
cluster-start:
	@$(CLUSTER_SCRIPT) start-cluster-installation

.PHONY: cluster-install
cluster-install:
	@$(CLUSTER_SCRIPT) cluster-install

.PHONY: wait-for-status
wait-for-status:
	@$(CLUSTER_SCRIPT) wait-for-status "$(STATUS)"

.PHONY: wait-for-ready
wait-for-ready:
	@$(MAKE) wait-for-status STATUS=ready

.PHONY: wait-for-installed
wait-for-installed:
	@$(MAKE) wait-for-status STATUS=installed

.PHONY: enable-storage
enable-storage:
	@$(MANIFESTS_SCRIPT) enable-storage

.PHONY: prepare-dpf-manifests
prepare-dpf-manifests:
	@$(MANIFESTS_SCRIPT) prepare-dpf-manifests

.PHONY: upgrade-management
upgrade-management:
	@scripts/upgrade-management.sh

.PHONY: upgrade-dpf
upgrade-dpf: install-helm
	@scripts/dpf-upgrade.sh interactive

.PHONY: deploy-argocd
deploy-argocd: install-helm
	@$(DPF_SCRIPT) deploy-argocd

.PHONY: deploy-maintenance-operator
deploy-maintenance-operator: install-helm
	@$(DPF_SCRIPT) deploy-maintenance-operator

.PHONY: deploy-dpf
deploy-dpf: prepare-dpf-manifests
	@$(DPF_SCRIPT) apply-dpf

.PHONY: prepare-dpu-files
prepare-dpu-files:
	@$(POST_INSTALL_SCRIPT) prepare

.PHONY: generate-overrides
generate-overrides:
	@$(POST_INSTALL_SCRIPT) generate-overrides

.PHONY: deploy-dpu-services
deploy-dpu-services: prepare-dpu-files
	@$(POST_INSTALL_SCRIPT) apply

.PHONY: deploy-observability
deploy-observability:
	@$(POST_INSTALL_SCRIPT) observability

.PHONY: deploy-hypershift
deploy-hypershift: install-helm
	@$(DPF_SCRIPT) deploy-hypershift

.PHONY: create-ignition-template
create-ignition-template:
	@$(DPF_SCRIPT) create-ignition-template

.PHONY: redeploy-dpu
redeploy-dpu:
	@$(POST_INSTALL_SCRIPT) redeploy

.PHONY: configure-flannel
configure-flannel: deploy-dpu-services
	@echo "✅ Flannel IPAM controller is deployed as part of DPU services"

.PHONY: enable-ovn-injector
enable-ovn-injector: install-helm
	@scripts/enable-ovn-injector.sh

.PHONY: deploy-core-operator-sources
deploy-core-operator-sources:
	@$(MANIFESTS_SCRIPT) deploy-core-operator-sources

.PHONY: update-etc-hosts
update-etc-hosts:
	@scripts/update-etc-hosts.sh update_etc_hosts

.PHONY: clean-all
clean-all:
	@$(CLUSTER_SCRIPT) clean-all
	@$(VM_SCRIPT) delete

.PHONY: kubeconfig
kubeconfig:
	@$(CLUSTER_SCRIPT) get-kubeconfig

.PHONY: kubeadmin-password
kubeadmin-password:
	@$(CLUSTER_SCRIPT) get-kubeadmin-password

.PHONY: deploy-nfd
deploy-nfd:
	@$(DPF_SCRIPT) deploy-nfd

.PHONY: deploy-metallb
deploy-metallb:
	@$(DPF_SCRIPT) deploy-metallb

.PHONY: deploy-lso
deploy-lso:
	@$(CLUSTER_SCRIPT) deploy-lso

.PHONY: deploy-odf
deploy-odf:
	@$(CLUSTER_SCRIPT) deploy-odf

.PHONY: deploy-lvms
deploy-lvms:
	@$(CLUSTER_SCRIPT) deploy-lvm

.PHONY: install-hypershift
install-hypershift:
	@$(TOOLS_SCRIPT) install-hypershift

.PHONY: install-helm
install-helm:
	@$(TOOLS_SCRIPT) install-helm

.PHONY: run-dpf-sanity
run-dpf-sanity:
	@echo "Running $(SANITY_CHECKS_SCRIPT) ..."
	@chmod +x $(SANITY_CHECKS_SCRIPT)
	@$(SANITY_CHECKS_SCRIPT)

# E2E Tests (library-import based, runs against pre-existing deployment)
E2E_GO_LABEL_FILTER ?= dpudeployment-lifecycle
E2E_GO_TIMEOUT ?= 90m
DPU_CLUSTER_NAME ?= $(HOSTED_CLUSTER_NAME)
DPU_DEPLOYMENT_NAME ?= dpudeployment
E2E_KUBECONFIG := $(abspath $(KUBECONFIG))

test-go-e2e:
	@echo "================================================================================"
	@echo "Running Go E2E tests (label-filter: $(E2E_GO_LABEL_FILTER))..."
	@echo "  KUBECONFIG: $(E2E_KUBECONFIG)"
	@echo "  HOSTED_CLUSTER_NAME: $(HOSTED_CLUSTER_NAME)"
	@echo "  DPU_CLUSTER_NAME: $(DPU_CLUSTER_NAME)"
	@echo "================================================================================"
	cd test && GOTOOLCHAIN=auto go test -v -count=1 -timeout $(E2E_GO_TIMEOUT) ./e2e/ \
		-ginkgo.v \
		-ginkgo.label-filter="$(E2E_GO_LABEL_FILTER)" \
		-e2e.kubeconfig="$(E2E_KUBECONFIG)" \
		-hosted-cluster-name="$(HOSTED_CLUSTER_NAME)" \
		-dpu-cluster-name="$(DPU_CLUSTER_NAME)" \
		-dpu-deployment-name="$(DPU_DEPLOYMENT_NAME)"

# Traffic Flow Tests
.PHONY: run-traffic-flow-tests
run-traffic-flow-tests:
	@echo "================================================================================"
	@echo "Running Traffic Flow Tests..."
	@echo "================================================================================"
	@$(TFT_SCRIPT) run-full

.PHONY: tft-setup
tft-setup:
	@echo "Setting up Traffic Flow Tests environment..."
	@$(TFT_SCRIPT) setup

.PHONY: tft-cleanup
tft-cleanup:
	@echo "Cleaning up Traffic Flow Tests..."
	@$(TFT_SCRIPT) cleanup

.PHONY: tft-show-config
tft-show-config:
	@$(TFT_SCRIPT) show-config

.PHONY: tft-results
tft-results:
	@$(TFT_SCRIPT) show-results

.PHONY: add-worker-nodes
add-worker-nodes:
	@echo "================================================================================"
	@echo "Adding worker nodes via BMO/Redfish provisioning..."
	@echo "================================================================================"
	@mkdir -p $(GENERATED_DIR)/worker-provisioning
	@$(WORKER_SCRIPT) provision-all-workers
	@if [ "$(AUTO_APPROVE_WORKER_CSR)" = "true" ]; then \
		echo ""; \
		echo "AUTO_APPROVE_WORKER_CSR=true - Deploying CSR auto-approver CronJob..."; \
		$(WORKER_SCRIPT) deploy-csr-auto-approver; \
	else \
		echo ""; \
		$(WORKER_SCRIPT) display-manual-csr-instructions; \
	fi
	@echo ""
	@echo "================================================================================"
	@echo "Worker node provisioning initiated!"
	@echo "Generated manifests: $(GENERATED_DIR)/worker-provisioning/"
	@echo "Run 'make worker-status' to monitor progress."
	@echo "================================================================================"

.PHONY: worker-status
worker-status:
	@$(WORKER_SCRIPT) display-worker-status

.PHONY: approve-worker-csrs
approve-worker-csrs:
	@$(WORKER_SCRIPT) approve-worker-csrs

.PHONY: deploy-csr-approver
deploy-csr-approver:
	@echo "Deploying CSR auto-approver for host cluster workers..."
	@$(WORKER_SCRIPT) deploy-csr-auto-approver

.PHONY: delete-csr-approver
delete-csr-approver:
	@$(WORKER_SCRIPT) delete-csr-auto-approver

.PHONY: delete-dpf-hcp-provisioner-operator
delete-dpf-hcp-provisioner-operator:
	@echo "Deleting DPF HCP Provisioner Operator..."
	@$(DPF_SCRIPT) delete-dpf-hcp-provisioner-operator

# Verification targets
.PHONY: verify-deployment
verify-deployment:
	@$(VERIFY_SCRIPT) verify-deployment

.PHONY: verify-workers
verify-workers:
	@$(VERIFY_SCRIPT) verify-workers

.PHONY: verify-dpu-nodes
verify-dpu-nodes:
	@$(VERIFY_SCRIPT) verify-dpu-nodes

.PHONY: verify-dpudeployment
verify-dpudeployment:
	@$(VERIFY_SCRIPT) verify-dpudeployment

.PHONY: validate-env-files
validate-env-files:
	@$(ENV_SCRIPT) validate-env-files

FORCE ?= false
.PHONY: generate-env
generate-env: validate-env-files
	@$(ENV_SCRIPT) generate-env $(FORCE)

.PHONY: help
help:
	@echo "Available targets:"
	@echo "Cluster Management:"
	@echo "  all               - Complete setup: verify, create cluster, VMs, install, and wait for completion"
	@echo "  create-cluster    - Create a new cluster"
	@echo "  create-day2-cluster - Create a day2 cluster for worker nodes with DPUs"
	@echo "  get-day2-iso      - Get ISO URL for worker nodes with DPUs (uses day2 cluster)"
	@echo "  download-iso      - Download the ISO for master nodes"
	@echo "  prepare-manifests - Prepare required manifests"
	@echo "  deploy-core-operator-sources - Deploy NFD & SR-IOV subscriptions and CatalogSource"
	@echo "  delete-cluster    - Delete the cluster"
	@echo "  clean            - Remove generated files"
	@echo "  clean-all        - Delete cluster, VMs, and clean all generated files"
	@echo ""
	@echo "VM Management:"
	@echo "  create-vms        - Create virtual machines for the cluster"
	@echo "  delete-vms        - Delete virtual machines"
	@echo "  add-vm-workers    - Add VM worker nodes via Assisted Installer day2 flow (full lifecycle)"
	@echo "  create-worker-vms - Create worker VMs from day2 ISO (idempotent, skips existing VMs)"
	@echo "  delete-worker-vms - Delete worker VMs"
	@echo "  download-day2-iso - Download day2 ISO for worker VMs (depends on create-day2-cluster)"
	@echo "  install-day2-hosts - Bind and start installation for discovered day2 hosts"
	@echo ""
	@echo "Installation and Status:"
	@echo "  cluster-install   - Start cluster installation (includes waiting for ready and installed status)"
	@echo "  cluster-start     - Start cluster installation without waiting"
	@echo "  wait-for-status   - Wait for specific cluster status (use STATUS=desired_status)"
	@echo "  wait-for-ready    - Wait for cluster ready status"
	@echo "  wait-for-installed - Wait for cluster installed status"
	@echo "  kubeconfig       - Download cluster kubeconfig if not exists"
	@echo "  kubeadmin-password - Download kubeadmin password for the cluster"
	@echo ""
	@echo "DPF Installation:"
	@echo "  deploy-argocd     - Deploy GitOps operator"
	@echo "  deploy-maintenance-operator - Deploy Maintenance Operator (standalone)"
	@echo "  deploy-dpf        - Deploy DPF operator (automatically deploys prerequisites for v25.7+)"
	@echo "  prepare-dpf-manifests - Prepare DPF installation manifests"
	@echo "  update-etc-hosts - Update /etc/hosts with cluster entries"
	@echo "  deploy-nfd       - Deploy NFD operator directly from source"
	@echo "  deploy-metallb   - Deploy MetalLB operator for LoadBalancer support (only if HYPERSHIFT_API_IP is set; IPAddressPool/L2Advertisement managed by dpf-hcp-provisioner-operator)"
	@echo "  deploy-lso       - Deploy Local Storage Operator for block storage (multi-node only; skipped if SKIP_DEPLOY_STORAGE=true)"
	@echo "  deploy-lso       - Deploy Local Storage Operator for block storage (multi-node only; skipped if SKIP_DEPLOY_STORAGE=true)"
	@echo "  deploy-lvms      - Deploy LVMS (Logical Volume Manager Storage) for etcd storage (default with STORAGE_TYPE=lvm)"
	@echo "  deploy-odf       - Deploy OpenShift Data Foundation for distributed storage (multi-node only, requires STORAGE_TYPE=odf)"
	@echo "  SKIP_DEPLOY_STORAGE=true - Use existing StorageClasses; set ETCD_STORAGE_CLASS to your StorageClass name"
	@echo "  upgrade-management - Upgrade management cluster OCP version (optional: MANAGEMENT_UPGRADE_TARGET_VERSION, defaults to z+1)"
	@echo "  upgrade-dpf       - Interactive DPF operator upgrade (user-friendly wrapper for prepare-dpf-manifests)"
	@echo "  prepare-dpu-files - Prepare post-installation manifests with custom values"
	@echo "  deploy-dpu-services - Deploy DPU services to the cluster"
	@echo "  configure-flannel - Deploy flannel IPAM controller for automatic podCIDR assignment"
	@echo "  add-worker-nodes  - Provision worker nodes via BMO/Redfish (uses WORKER_* env vars)"
	@echo "  worker-status     - Display provisioning status for all configured workers"
	@echo "  approve-worker-csrs - Approve pending CSRs (one-time, for manual use)"
	@echo "  deploy-csr-approver - Deploy CSR auto-approver CronJob for host cluster workers"
	@echo "  delete-csr-approver - Remove CSR auto-approver from host cluster"
	@echo "  delete-dpf-hcp-provisioner-operator - Remove DPF HCP Provisioner Operator and related resources"
	@echo ""
	@echo "Verification:"
	@echo "  verify-deployment     - Full verification: workers + DPU nodes + DPUDeployment"
	@echo "  verify-workers        - Wait for worker nodes to be Ready in host cluster"
	@echo "  verify-dpu-nodes      - Wait for DPU nodes to be Ready in DPUCluster"
	@echo "  verify-dpudeployment  - Wait for DPUDeployment to be Ready"
	@echo ""
	@echo "E2E Tests:"
	@echo "  test-go-e2e            - Run Go e2e tests (E2E_GO_LABEL_FILTER=dpudeployment-lifecycle)"
	@echo ""
	@echo "Traffic Flow Tests:"
	@echo "  run-traffic-flow-tests - Run kubernetes-traffic-flow-tests for network validation"
	@echo "  tft-setup              - Setup TFT repository and Python environment only"
	@echo "  tft-cleanup            - Remove TFT repository and virtual environment"
	@echo "  tft-show-config        - Display current TFT configuration"
	@echo "  tft-results            - Show results from the most recent test run"
	@echo ""
	@echo "Hypershift Management:"
	@echo "  install-hypershift - Install Hypershift binary and operator"
	@echo "  create-hypershift-cluster - Create a new Hypershift hosted cluster"
	@echo "  configure-hypershift-dpucluster - Configure DPF to use Hypershift hosted cluster"
	@echo ""
	@echo "Configuration options:"
	@echo "Cluster Configuration:"
	@echo "  CLUSTER_NAME      - Set cluster name (default: $(CLUSTER_NAME))"
	@echo "  BASE_DOMAIN      - Set base DNS domain (default: $(BASE_DOMAIN))"
	@echo "  OPENSHIFT_VERSION - Set OpenShift version (default: $(OPENSHIFT_VERSION))"
	@echo "  KUBECONFIG       - Path to kubeconfig file (default: $(KUBECONFIG))"
	@echo ""
	@echo "Feature Configuration:"
	@echo "  DISABLE_NFD       - Skip NFD deployment (default: $(DISABLE_NFD))"
	@echo ""
	@echo "Hypershift Configuration:"
	@echo "  HYPERSHIFT_IMAGE  - Hypershift operator image (default: $(HYPERSHIFT_IMAGE))"
	@echo "  HOSTED_CLUSTER_NAME - Name of the hosted cluster (default: $(HOSTED_CLUSTER_NAME))"
	@echo "  CLUSTERS_NAMESPACE - Namespace for clusters (default: $(CLUSTERS_NAMESPACE))"
	@echo "  OCP_RELEASE_IMAGE - OCP release image for hosted cluster (default: $(OCP_RELEASE_IMAGE))"
	@echo ""
	@echo "Network Configuration:"
	@echo "  POD_CIDR         - Set pod CIDR (default: $(POD_CIDR))"
	@echo "  SERVICE_CIDR     - Set service CIDR (default: $(SERVICE_CIDR))"
	@echo "  API_VIP          - Set API VIP address"
	@echo "  INGRESS_VIP      - Set Ingress VIP address"
	@echo ""
	@echo "VM Configuration:"
	@echo "  VM_COUNT         - Number of VMs to create (default: $(VM_COUNT))"
	@echo "  RAM              - RAM in MB for VMs (default: $(RAM))"
	@echo "  VCPUS            - Number of vCPUs for VMs (default: $(VCPUS))"
	@echo "  DISK_SIZE1       - Primary disk size in GB (default: $(DISK_SIZE1))"
	@echo "  DISK_SIZE2       - Secondary disk size in GB (default: $(DISK_SIZE2))"
	@echo "  LIBVIRT_HOST     - Remote libvirt host for VM hosting (e.g., root@192.168.1.100; default: local)"
	@echo ""
	@echo "VM Worker Configuration (day2 Assisted Installer flow):"
	@echo "  VM_WORKER_COUNT      - Number of worker VMs to create (default: 0)"
	@echo "  VM_WORKER_PREFIX     - VM name prefix for workers (default: VM_PREFIX-worker)"
	@echo "  VM_WORKER_RAM        - RAM in MB for worker VMs (default: same as RAM)"
	@echo "  VM_WORKER_VCPUS      - Number of vCPUs for worker VMs (default: same as VCPUS)"
	@echo "  VM_WORKER_DISK_SIZE1 - Primary disk size in GB for worker VMs (default: same as DISK_SIZE1)"
	@echo "  VM_WORKER_DISK_SIZE2 - Secondary disk size in GB for worker VMs (default: same as DISK_SIZE2)"
	@echo ""
	@echo "DPF Configuration:"
	@echo "  DPF_VERSION      - DPF operator version (default: $(DPF_VERSION))"
	@echo "  SKIP_DEPLOY_STORAGE - If true, skip LSO/LVM/ODF deployment; ETCD_STORAGE_CLASS must point to existing StorageClass (default: false)"
	@echo "  ETCD_STORAGE_CLASS - StorageClass for hosted cluster etcd (default: $(ETCD_STORAGE_CLASS)); required when SKIP_DEPLOY_STORAGE=true"
	@echo ""
	@echo "MetalLB Configuration:"
	@echo "  HYPERSHIFT_API_IP     - IP address for Hypershift API server LoadBalancer"
	@echo "                          If set: Deploys MetalLB and uses LoadBalancer for Hypershift API (dpf-hcp-provisioner-operator manages IPAddressPool/L2Advertisement)"
	@echo "                          If not set: Uses NodePort for Hypershift API (multi-node) or default (single-node)"
	@echo ""
	@echo "Post-installation Configuration:"
	@echo "  BFB_URL          - URL for BFB file (default: http://10.8.2.236/bfb/rhcos_4.19.0-ec.4_installer_2025-04-23_07-48-42.bfb)"
	@echo "  HBN_OVN_NETWORK  - Network for HBN OVN IPAM (default: 10.0.120.0/22)"
	@echo ""
	@echo "Wait Configuration:"
	@echo "  MAX_RETRIES      - Maximum number of retries for status checks (default: $(MAX_RETRIES))"
	@echo "  SLEEP_TIME       - Sleep time in seconds between retries (default: $(SLEEP_TIME))"
	@echo ""
	@echo "Worker Node Configuration:"
	@echo "  WORKER_COUNT          - Number of workers to provision (default: 0)"
	@echo "  WORKER_n_NAME         - Worker hostname (e.g., WORKER_1_NAME=openshift-worker-1)"
	@echo "  WORKER_n_BMC_IP       - BMC/iDRAC IP address for Redfish API"
	@echo "  WORKER_n_BMC_USER     - BMC username"
	@echo "  WORKER_n_BMC_PASSWORD - BMC password"
	@echo "  WORKER_n_BOOT_MAC     - Boot NIC MAC address"
	@echo "  WORKER_n_ROOT_DEVICE  - Target installation disk (e.g., /dev/sda)"
	@echo "  WORKER_n_DPU          - Set to 'false' for regular workers, defualt is true (worker-dpu)"
	@echo "  WORKER_NODE_LABELS    - Comma-separated labels for kubelet --node-labels (e.g., node.openshift.io/dpu-host=true)"
	@echo ""
	@echo "CSR Auto-Approval Configuration:"
	@echo "  AUTO_APPROVE_WORKER_CSR     - Deploy CronJob to auto-approve CSRs for host cluster workers (default: false)"
	@echo ""
	@echo "Verification Configuration:"
	@echo "  VERIFY_DEPLOYMENT    - Run verification after 'make all' completes (default: false)"
	@echo "  VERIFY_MAX_RETRIES   - Max retry attempts for verification (default: 60)"
	@echo "  VERIFY_SLEEP_SECONDS - Seconds between verification retries (default: 30)"
	@echo ""
	@echo "Traffic Flow Tests Configuration:"
	@echo "  TFT_REPO_URL         - TFT git repository URL"
	@echo "  TFT_REPO_REV         - Git revision/branch/tag to checkout (default: main)"
	@echo "  TFT_TEST_CASES       - Test cases to run (default: 1-25)"
	@echo "  TFT_DURATION         - Duration per test in seconds (default: 10)"
	@echo "  TFT_CONNECTION_TYPE  - Test type: iperf-tcp, iperf-udp, etc. (default: iperf-tcp)"
	@echo "  TFT_KUBECONFIG       - Path to cluster kubeconfig"
	@echo "  TFT_SERVER_NODE      - K8s node name for server (default: from HBN_HOSTNAME_NODE1)"
	@echo "  TFT_CLIENT_NODE      - K8s node name for client (default: from HBN_HOSTNAME_NODE2)"
