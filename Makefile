# Include environment variables
include .env

# Export variables to child processes
export

# Script paths
CLUSTER_SCRIPT := scripts/cluster.sh
MANIFESTS_SCRIPT := scripts/manifests.sh
TOOLS_SCRIPT := scripts/tools.sh
DPF_SCRIPT := scripts/dpf.sh
VM_SCRIPT := scripts/vm.sh
UTILS_SCRIPT := scripts/utils.sh
POST_INSTALL_SCRIPT := scripts/post-install.sh
NFS_SERVICE_SCRIPT := scripts/nfs-service.sh

# Sanity tests script:
SANITY_CHECKS_SCRIPT := scripts/dpf-sanity-checks.sh

# Worker provisioning script
WORKER_SCRIPT := scripts/worker.sh

.PHONY: all clean check-cluster create-cluster prepare-manifests generate-ovn update-paths help delete-cluster verify-files \
        download-iso fix-yaml-spacing create-vms delete-vms enable-storage cluster-install wait-for-ready \
        wait-for-installed wait-for-status cluster-start clean-all deploy-dpf kubeconfig kubeadmin-password deploy-nfd \
        install-hypershift install-helm deploy-dpu-services prepare-dpu-files upgrade-dpf create-day2-cluster get-day2-iso \
        redeploy-dpu enable-ovn-injector deploy-argocd deploy-maintenance-operator configure-flannel \
        deploy-core-operator-sources setup-nfs-server deploy-metallb deploy-lso deploy-odf deploy-lvms prepare-nfs run-dpf-sanity \
        add-worker-nodes worker-status approve-worker-csrs \
        deploy-csr-approver delete-csr-approver deploy-dpucluster-csr-approver delete-dpucluster-csr-approver

all: 
	@mkdir -p logs
	@bash -o pipefail -c '$(MAKE) _all 2>&1 | tee "logs/make_all_$(shell date +%Y%m%d_%H%M%S).log"'

_all: verify-files check-cluster create-vms prepare-manifests cluster-install update-etc-hosts kubeconfig deploy-dpf prepare-dpu-files deploy-dpu-services enable-ovn-injector add-worker-nodes
	@echo ""
	@echo "================================================================================"
	@echo "✅ DPF Installation Complete!"
	@echo "================================================================================"
	@echo ""
	@echo "Worker nodes have been provisioned via BMO/Redfish."
	@echo "Run 'make worker-status' to check provisioning progress."
	@echo ""
	@echo "Note: Worker nodes will show NotReady until DPU services are fully configured."
	@echo "================================================================================"

verify-files:
	@$(UTILS_SCRIPT) verify-files

clean:
	@$(CLUSTER_SCRIPT) clean

delete-cluster:
	@$(CLUSTER_SCRIPT) delete-cluster

check-cluster:
	@$(CLUSTER_SCRIPT) check-create-cluster

create-cluster:
	@$(CLUSTER_SCRIPT) check-create-cluster

create-day2-cluster:
	@$(CLUSTER_SCRIPT) create-day2-cluster

get-day2-iso: create-day2-cluster
	@$(CLUSTER_SCRIPT) get-day2-iso

prepare-manifests:
	@$(MANIFESTS_SCRIPT) prepare-manifests

generate-ovn:
	@$(MANIFESTS_SCRIPT) generate-ovn-manifests

update-paths:
	@$(MANIFESTS_SCRIPT) prepare-manifests

download-iso:
	@$(CLUSTER_SCRIPT) download-iso

create-vms: download-iso
	@$(VM_SCRIPT) create

delete-vms:
	@$(VM_SCRIPT) delete

cluster-start:
	@$(CLUSTER_SCRIPT) start-cluster-installation

cluster-install:
	@$(CLUSTER_SCRIPT) cluster-install

wait-for-status:
	@$(CLUSTER_SCRIPT) wait-for-status "$(STATUS)"

wait-for-ready:
	@$(MAKE) wait-for-status STATUS=ready

wait-for-installed:
	@$(MAKE) wait-for-status STATUS=installed

enable-storage:
	@$(MANIFESTS_SCRIPT) enable-storage

prepare-dpf-manifests:
	@$(MANIFESTS_SCRIPT) prepare-dpf-manifests

upgrade-dpf: install-helm
	@scripts/dpf-upgrade.sh interactive

deploy-argocd: install-helm
	@$(DPF_SCRIPT) deploy-argocd

deploy-maintenance-operator: install-helm
	@$(DPF_SCRIPT) deploy-maintenance-operator

deploy-dpf: prepare-dpf-manifests
	@$(DPF_SCRIPT) apply-dpf

prepare-dpu-files:
	@$(POST_INSTALL_SCRIPT) prepare

deploy-dpu-services: prepare-dpu-files
	@$(POST_INSTALL_SCRIPT) apply

deploy-hypershift:
	@$(DPF_SCRIPT) deploy-hypershift

create-ignition-template:
	@$(DPF_SCRIPT) create-ignition-template

redeploy-dpu:
	@$(POST_INSTALL_SCRIPT) redeploy

configure-flannel: deploy-dpu-services
	@echo "✅ Flannel IPAM controller is deployed as part of DPU services"

enable-ovn-injector: install-helm
	@scripts/enable-ovn-injector.sh

deploy-core-operator-sources:
	@$(MANIFESTS_SCRIPT) deploy-core-operator-sources

update-etc-hosts:
	@scripts/update-etc-hosts.sh update_etc_hosts

clean-all:
	@$(CLUSTER_SCRIPT) clean-all
	@$(VM_SCRIPT) delete

kubeconfig:
	@$(CLUSTER_SCRIPT) get-kubeconfig

kubeadmin-password:
	@$(CLUSTER_SCRIPT) get-kubeadmin-password

deploy-nfd:
	@$(DPF_SCRIPT) deploy-nfd

deploy-metallb:
	@$(DPF_SCRIPT) deploy-metallb

deploy-lso:
	@$(CLUSTER_SCRIPT) deploy-lso

deploy-odf:
	@$(CLUSTER_SCRIPT) deploy-odf

deploy-lvms:
	@echo "INFO: LVMS is configured during cluster installation when STORAGE_TYPE=lvm (default)"
	@echo "INFO: LVMS operator is deployed via assisted installer OLM during cluster creation"
	@echo "INFO: Use 'make enable-storage' during cluster setup to configure LVMS"
	@echo "INFO: To manually deploy LVMS post-installation, set STORAGE_TYPE=lvm and run 'make cluster-install'"

prepare-nfs:
	@$(MANIFESTS_SCRIPT) prepare-nfs

install-hypershift:
	@$(TOOLS_SCRIPT) install-hypershift

install-helm:
	@$(TOOLS_SCRIPT) install-helm

setup-nfs-server:
	@$(NFS_SERVICE_SCRIPT)

run-dpf-sanity:
	@echo "Running $(SANITY_CHECKS_SCRIPT) ..."
	@chmod +x $(SANITY_CHECKS_SCRIPT)
	@$(SANITY_CHECKS_SCRIPT)

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

worker-status:
	@$(WORKER_SCRIPT) display-worker-status

approve-worker-csrs:
	@$(WORKER_SCRIPT) approve-worker-csrs

deploy-csr-approver:
	@echo "Deploying CSR auto-approver for host cluster workers..."
	@$(WORKER_SCRIPT) deploy-csr-auto-approver

delete-csr-approver:
	@$(WORKER_SCRIPT) delete-csr-auto-approver

deploy-dpucluster-csr-approver:
	@echo "Deploying CSR auto-approver for DPUCluster..."
	@$(DPF_SCRIPT) deploy-dpucluster-csr-approver

delete-dpucluster-csr-approver:
	@$(DPF_SCRIPT) delete-dpucluster-csr-approver

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
	@echo "  deploy-metallb   - Deploy MetalLB operator for LoadBalancer support (only if HYPERSHIFT_API_IP is set)"
	@echo "  deploy-lso       - Deploy Local Storage Operator for block storage (multi-node only)"
	@echo "  deploy-lvms      - Deploy LVMS (Logical Volume Manager Storage) for etcd storage (default with STORAGE_TYPE=lvm)"
	@echo "  deploy-odf       - Deploy OpenShift Data Foundation for distributed storage (multi-node only, requires STORAGE_TYPE=odf)"
	@echo "  prepare-nfs      - Prepare NFS manifests (internal or external NFS based on configuration)"
	@echo "  upgrade-dpf       - Interactive DPF operator upgrade (user-friendly wrapper for prepare-dpf-manifests)"
	@echo "  prepare-dpu-files - Prepare post-installation manifests with custom values"
	@echo "  deploy-dpu-services - Deploy DPU services to the cluster"
	@echo "  configure-flannel - Deploy flannel IPAM controller for automatic podCIDR assignment"
	@echo "  add-worker-nodes  - Provision worker nodes via BMO/Redfish (uses WORKER_* env vars)"
	@echo "  worker-status     - Display provisioning status for all configured workers"
	@echo "  approve-worker-csrs - Approve pending CSRs (one-time, for manual use)"
	@echo "  deploy-csr-approver - Deploy CSR auto-approver CronJob for host cluster workers"
	@echo "  delete-csr-approver - Remove CSR auto-approver from host cluster"
	@echo "  deploy-dpucluster-csr-approver - Deploy CSR auto-approver for DPUCluster (runs on host)"
	@echo "  delete-dpucluster-csr-approver - Remove CSR auto-approver for DPUCluster"
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
	@echo "  NFD_OPERAND_IMAGE - (deprecated - no longer used)"
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
	@echo "  DPU_INTERFACE    - Set DPU interface (default: $(DPU_INTERFACE))"
	@echo "  API_VIP          - Set API VIP address"
	@echo "  INGRESS_VIP      - Set Ingress VIP address"
	@echo ""
	@echo "VM Configuration:"
	@echo "  VM_COUNT         - Number of VMs to create (default: $(VM_COUNT))"
	@echo "  RAM              - RAM in MB for VMs (default: $(RAM))"
	@echo "  VCPUS            - Number of vCPUs for VMs (default: $(VCPUS))"
	@echo "  DISK_SIZE1       - Primary disk size in GB (default: $(DISK_SIZE1))"
	@echo "  DISK_SIZE2       - Secondary disk size in GB (default: $(DISK_SIZE2))"
	@echo ""
	@echo "DPF Configuration:"
	@echo "  DPF_VERSION      - DPF operator version (default: $(DPF_VERSION))"
	@echo "  ETCD_STORAGE_CLASS - StorageClass for hosted cluster etcd (default: $(ETCD_STORAGE_CLASS))"
	@echo "  BFB_STORAGE_CLASS - StorageClass for BFB PVC (default: $(BFB_STORAGE_CLASS))"
	@echo ""
	@echo "MetalLB Configuration:"
	@echo "  HYPERSHIFT_API_IP     - IP address for Hypershift API server LoadBalancer"
	@echo "                          If set: Deploys MetalLB and uses LoadBalancer for Hypershift API"
	@echo "                          If not set: Uses NodePort for Hypershift API (multi-node) or default (single-node)"
	@echo ""
	@echo "NFS Configuration:"
	@echo "  NFS_SERVER_NODE_IP    - External NFS server IP (if set, uses external NFS; otherwise internal)"
	@echo "  NFS_PATH              - NFS export path (default: /)"
	@echo ""
	@echo "Post-installation Configuration:"
	@echo "  BFB_URL          - URL for BFB file (default: http://10.8.2.236/bfb/rhcos_4.19.0-ec.4_installer_2025-04-23_07-48-42.bfb)"
	@echo "  HBN_OVN_NETWORK  - Network for HBN OVN IPAM (default: 10.0.120.0/22)"
	@echo ""
	@echo "NFS Server Setup:"
	@echo "  setup-nfs-server - Setup NFS server with systemd service and firewall configuration"
	@echo "                     Environment variables:"
	@echo "                       NFS_EXPORT_DIR     - Export directory path (default: /nfs/exports)"
	@echo "                       NFS_EXPORT_OPTIONS - Export options (default: rw,sync,no_root_squash,no_subtree_check)"
	@echo "                       NFS_ALLOWED_NETWORK - Allowed network/host (default: *)"
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
	@echo ""
	@echo "CSR Auto-Approval Configuration:"
	@echo "  AUTO_APPROVE_WORKER_CSR     - Deploy CronJob to auto-approve CSRs for host cluster workers (default: false)"
	@echo "  AUTO_APPROVE_DPUCLUSTER_CSR - Deploy CronJob to auto-approve CSRs for DPUCluster nodes (default: false)" 
