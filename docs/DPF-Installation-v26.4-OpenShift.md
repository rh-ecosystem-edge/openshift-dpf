DPF Installation On OpenShift User Manual
(Technical Preview)

Revision: 2.0
Date: 06.03.2026

---

**Product**: NVIDIA DPU Platform Framework (DPF) v26.4.0
**Platform**: Red Hat OpenShift Container Platform 4.22
**Hardware**: NVIDIA BlueField-3 DPU
**Classification**: Internal / Partner Use

---

Legal Notices

Copyright 2026 NVIDIA Corporation. All rights reserved.

NVIDIA, the NVIDIA logo, BlueField, DOCA, and DPF are trademarks and/or registered trademarks of NVIDIA Corporation in the United States and other countries.

Red Hat, Red Hat Enterprise Linux, the Red Hat logo, and OpenShift are trademarks or registered trademarks of Red Hat, Inc. or its subsidiaries in the United States and other countries.

---

Support Information

For technical support:
- **NVIDIA Enterprise Support**: https://enterprise-support.nvidia.com
- **Red Hat Support**: https://access.redhat.com
- **Documentation Issues**: Contact your platform engineering team

---

References

- NVIDIA DPF Official Documentation: https://docs.nvidia.com/networking/display/dpfv2640/
- Red Hat OpenShift Container Platform 4.22 Documentation: https://docs.openshift.com/container-platform/4.22/welcome/index.html
- Red Hat Developer Blog -- DPU-Enabled Networking: https://developers.redhat.com/articles/2025/03/20/dpu-enabled-networking-openshift-and-nvidia-dpf
- NVIDIA BlueField-3 DPU Documentation: https://docs.nvidia.com/networking/display/bluefield3lts/
- Red Hat Multicluster Engine (MCE) Documentation: https://docs.openshift.com/container-platform/4.22/architecture/mce-overview-ocp.html
- dpf-hcp-provisioner-operator: https://github.com/openshift/dpf-hcp-provisioner-operator

---

# Table of Contents

## Chapter 1: Architecture Overview
- 1.1 The Topology
- 1.2 Example Lab Topology
- 1.3 Architectural Benefits
- 1.4 Component Placement
- 1.5 Deployment Flow Overview

## Chapter 2: Prerequisites
- 2.1 Hardware Requirements
  - 2.1.1 Workstation
  - 2.1.2 Control Plane Nodes
  - 2.1.3 Worker Nodes
  - 2.1.4 NVIDIA BlueField-3 DPUs
- 2.2 Network Infrastructure
- 2.3 Software Requirements
- 2.4 DNS, Access, Storage, and Security
- 2.5 Additional Guidance

## Chapter 3: Management Cluster Setup
- 3.1 Overview
- 3.2 Installation Method
  - 3.2.1 Cluster Installation
  - 3.2.2 Cluster State Verification

## Chapter 4: Environment Setup
- 4.1 Worker Node Configuration
  - 4.1.1 Worker MachineConfig Resources
  - 4.1.2 MachineConfig Decoded Scripts
- 4.2 Cluster Configuration
  - 4.2.1 Custom Cluster Feature -- MutatingAdmissionPolicy
  - 4.2.2 Control Plane Node Patching
  - 4.2.3 Create DPF Namespace
- 4.3 Operators Installation
  - 4.3.1 Cert Manager Operator
  - 4.3.2 Node Feature Discovery Operator
  - 4.3.3 SR-IOV Network Operator
  - 4.3.4 MetalLB Operator
  - 4.3.5 Red Hat OpenShift GitOps Operator
  - 4.3.6 Multicluster Engine (MCE) Operator
  - 4.3.7 Maintenance Operator CRD
- 4.4 Operator Configuration
  - 4.4.1 Configure NFD Operator
  - 4.4.2 Configure SR-IOV Operator
  - 4.4.3 Configure MetalLB Operator
  - 4.4.4 Configure GitOps Operator
  - 4.4.5 Configure Cluster Network Operator
- 4.5 Custom SR-IOV Device Plugin

## Chapter 5: DPF Operator Installation and Configuration
- 5.1 Environment Variables
- 5.2 Create DPU Image Storage Objects
- 5.3 Install DPF Operator
- 5.4 Generate BF.cfg ConfigMap
- 5.5 Create DPF Resources
  - 5.5.1 DPFOperatorConfig
  - 5.5.2 NodeSRIOVDevicePluginConfig
  - 5.5.3 DPUFlavor
  - 5.5.4 BFB
  - 5.5.5 DPUDeployment
- 5.6 Create DPU Services Resources
  - 5.6.1 HBN DPU Service
  - 5.6.2 OVN-Kubernetes DPU Service
  - 5.6.3 OVN-Kubernetes DPUServiceCredentialRequest
  - 5.6.4 DPUServiceInterface Physical
  - 5.6.5 DPUServiceInterface OVN-Kubernetes
  - 5.6.6 DPUServiceNADs
  - 5.6.7 DPUServiceIPAM
  - 5.6.8 DOCA Telemetry Service
- 5.7 Verify DPU Services Resources

## Chapter 6: Hosted Cluster for DPU Control-Plane
- 6.1 Install dpf-hcp-provisioner-operator
- 6.2 Define Environment Variables
- 6.3 Create DPFHCPProvisioner Secrets
- 6.4 Create DPUCluster Resource
- 6.5 Create DPFHCPProvisioner Resource
- 6.6 Verify Hosted Cluster Creation

## Chapter 7: OVN-Kubernetes CNI Adjustments
- 7.1 Enable OVN-Kubernetes Resource Injector
- 7.2 Enable OVN-Kubernetes DPU-Host Mode

## Chapter 8: Adding Worker Nodes
- 8.1 Prerequisites
- 8.2 Add Worker Nodes
  - 8.2.1 Option 1: Adding Worker Nodes Using Assisted Installer
  - 8.2.2 Option 2: Adding Worker Nodes Using Baremetal Operator
- 8.3 Approve Worker Nodes Certificate Requests
- 8.4 Verify DPU Provisioning
- 8.5 Authorization Configuration for the Hosted DPU Cluster Components
- 8.6 DPU CSR Approval
- 8.7 Verify Cluster Readiness

## Chapter 9: Traffic Validation Test
- 9.1 Create Traffic Test Pods/Services
- 9.2 Run Traffic Validation Tests

## Chapter 10: DPU Telemetry (DTS) Observability on OpenShift
- 10.1 How DPF Exposes DTS Metrics to the Management Cluster

## Chapter 11: Basic Troubleshooting
- 11.1 DPU Provisioning
- 11.2 DPU Object State
- 11.3 Management Cluster Nodes State
- 11.4 dpf-hcp-provisioner-operator Issues

## Chapter 12: Appendix
- 12.1 Unsupported OVN Kubernetes Features
- 12.2 Complete Resource Application Order
- 12.3 Environment Variables Quick Reference

---

# Chapter 1: Architecture Overview

This chapter describes the architecture of the NVIDIA DPU Platform Framework (DPF) v26.4 deployment on Red Hat OpenShift Container Platform 4.22. The deployment creates a dual-cluster topology that offloads OVN-Kubernetes data plane operations to NVIDIA BlueField-3 DPUs, providing hardware-accelerated networking for enterprise workloads.

## 1.1 The Topology
The architecture consists of two distinct OpenShift clusters operating on the same physical server hardware:
OpenShift Management Cluster:
Location: Runs on the server's main x86 CPU cores.
Role: Hosts the actual business logic, such as AI workloads or enterprise applications.
Components: Red Hat OpenShift worker nodes containing Application Pods.
Networking: The Application Pods on the worker node rely on the DPU accelerated network; the host OS sees accelerated interfaces (e.g., SR-IOV VFs or SFs) but does not manage the network control plane.
Role: It serves as the primary administrative interface and the "Host Cluster" that provisions and manages both the fleet of DPUs and the users workloads. In a Host Trusted deployment, the worker nodes in this cluster are the physical servers that house the BlueField DPUs. It is responsible for the lifecycle management of the DPU hardware and the orchestration system running on the DPUs.
Deployment:
User Workloads: The actual AI or Telco applications running on the x86 host processors reside here
DPF Operator: The core operator that installs and configures the DPF system.
Control Plane Components: It hosts the DPU Cluster Control Plane (using HyperShift via the dpf-hcp-provisioner-operator to run the control plane as pods) which manages the separate cluster running on the DPUs.
Controllers: Various controllers run here, including the Provisioning Controllers (BFB, DPUSet, DPU, DPUCluster), DPUService Controllers (to manage apps on the DPU), and DPUServiceChain Controllers.
Usage:
Run users workloads    
Single Pane of Glass: Users interact with this cluster to define the desired state of the infrastructure using Kubernetes Custom Resource Definitions (CRDs) like DPUSet, DPUDeployment, and DPUService.
    Provisioning: It drives the discovery of DPUs, flashes the BlueField Bootstream (BFB) images, and configures the host-to-DPU networking.
    Orchestration: It coordinates the deployment of services and network flows down to the DPU Cluster
OpenShift DPU Hosted Cluster:
Role: The OpenShift DPU Hosted Cluster serves as a dedicated, secondary Kubernetes control plane specifically for managing the fleet of NVIDIA BlueField DPUs. In this architecture, the DPUs themselves function as the worker nodes of this hosted cluster, distinct from the bare-metal hosts they are physically attached to. This separates the management domain of the infrastructure acceleration hardware from the tenant workloads running on the main host servers.
Deployment: This cluster hosts the infrastructure software and DOCA services required to operate the DPU. Key components deployed on it include:
Networking Stack: OVN-Kubernetes (running in DPU mode to offload flows). 
 DOCA Services: Specialized applications such as Host-Based Networking (HBN) for BGP routing, DOCA Telemetry Service (DTS) for monitoring, and Firefly for time synchronization.
System Components: NVIDIA IPAM, Multus, and SR-IOV Device Plugins to manage the DPU's hardware resources.
Usage: It is used to orchestrate and lifecycle-manage the software running on the DPU independently of the host. Its primary functions are to offload critical networking (like OVS processing) from the host CPU to the DPU, isolate infrastructure services for better security, and perform Service Function Chaining to route traffic through specific network functions (e.g., firewalls or encryption) directly on the hardware

## 1.2 Example Lab Topology
The following diagram illustrates the physical connectivity for a reference lab environment. It serves as a baseline example to demonstrate the core components and their interactions.

## 1.3 Architectural Benefits
### 1.3.1 Operational Simplicity and Integrated Management
Host-Based Management: In a Host Trusted deployment, the DPU is managed from the host. This model allows cloud operators to manage BlueField-bound services directly from their standard OpenShift control plane, providing a "single pane of glass" view for both OpenShift tenant nodes and DPUs.
Streamlined Deployment: DPF in this mode facilitates the automated discovery and provisioning of DPUs. The DPF Operator detects worker nodes, creates DPU objects, and deploys the DOCA Management Service (DMS) to flash the BlueField Boot (BFB) firmware and configure networking between the host and DPU.
Reduced Complexity: This mode eliminates the complexity of low-level device configuration by utilizing standard Kubernetes APIs and workflows for the DPU lifecycle.
### 1.3.2 Accelerated Infrastructure
Resource Offloading: In Host Trusted mode, the architecture allows for the offloading of infrastructure services—such as networking, storage, and security—from the host CPU to the DPU. This frees up host CPU resources for applications and boosts infrastructure performance. The upcoming release is focused on networking services.
Hardware Acceleration: The framework enables the creation of hardware-accelerated, software-defined solutions that manage data center traffic and storage through dedicated ports on the BlueField DPU.
### 1.3.3 Kubernetes Native Orchestration
Seamless Integration: DPF extends Kubernetes control plane functionality to the DPUs, enabling administrators to deploy and orchestrate NVIDIA DOCA services and third-party applications directly on the BlueField DPU using familiar Kubernetes constructs.
Automated Lifecycle Management: The architecture supports automated rolling updates, scaling, and rollbacks for services, allowing administrators to manage changes efficiently without disrupting ongoing operations.
It is important to note that in Host Trusted mode, the host is part of the trusted domain.

## 1.4 Component Placement
The various software components and operators are strategically placed across the two clusters to maintain this separation.

### 1.4.1 Management Components

The following operators and services run within the management cluster:
NVIDIA DPF Operator: The core operator that manages DPU services and configurations within the hosted cluster, including DPU provisioning, networking acceleration, and DOCA service orchestration
dpf-hcp-provisioner-operator: Automates the entire HyperShift hosted cluster lifecycle. It creates HostedCluster resources, manages MetalLB IPAddressPool/L2Advertisement, injects kubeconfig into DPUCluster, and automatically approves DPU CSRs. This replaces the manual HyperShift cluster creation workflow from previous versions.
MultiCluster Engine (MCE) & HyperShift: Provide the control plane and management framework for the DPU-hosted cluster.
Node Feature Discovery (NFD) Operator: Discovers and labels hardware features on the nodes, including the presence of DPUs.
MetalLB Operator: Provides load-balancing services for the management cluster.
GitOps Operator: Facilitates ArgoCD based deployment of applications and configurations.
Cert-Manager Operator: Automates the management, issuance, and renewal of TLS certificates within the cluster.
NVIDIA Maintenance Operator: Assists in performing maintenance tasks and gracefully draining DPU worker nodes.
LVM Storage Operator: Provides persistent ReadWriteMany (RWX) storage required for various components, such as the etcd database of the hosted cluster.
NodeSRIOVDevicePluginConfig: A DPF-managed CRD that configures SR-IOV device plugin pods on worker nodes. This replaces the standalone custom SR-IOV device plugin DaemonSet and control plane node patching from previous versions. It defines VF allocation ranges for management and workload traffic.
Baremetal Operator: Provisions and adds worker nodes with DPUs to the management cluster

## 1.5 Deployment Flow Overview

The end-to-end deployment process follows these high-level steps:
Management Cluster Setup: A standard OCP cluster is installed and configured on the x86 servers (control-plane nodes only).
Management Cluster Configuration: Nodes and cluster level configuration, followed by operators installation and configuration on the management cluster.
Hosted Cluster Creation: The dpf-hcp-provisioner-operator automates the creation of a hosted DPU cluster via HyperShift (Chapter 6). A DPFHCPProvisioner resource is created which handles HostedCluster creation, MetalLB configuration, kubeconfig injection into DPUCluster, and DPU CSR approval.
DPF Installation: DPF Operator, controllers and related components are deployed on the management cluster (Chapter 5). The NodeSRIOVDevicePluginConfig is created to manage SR-IOV VF allocation on worker nodes.
Worker Nodes Scale-Out and DPU Provisioning: The moment worker nodes with DPUs are added to the cluster, the DPF Operator flashes the DPUs with a Red Hat Enterprise Linux CoreOS (RHCOS) image and configures them to join the hosted cluster as worker nodes.
Service Deployment: Once the DPU-hosted cluster is operational, data plane DPU services and chains are automatically deployed by DPF.
Workload Deployment: Test pods utilizing the DPU services and chains are created and can communicate over DPU-accelerated network.

---

# Chapter 2: Prerequisites

This chapter outlines the prerequisites for deploying the DPF Operator. Fulfilling these hardware, software, and environmental requirements is essential for setting up the architecture described in Chapter 1.

## 2.1 Hardware Requirements

### 2.1.1 Workstation
A workstation with the following command-line interface (CLI) tools installed:
OpenShift CLI (oc) - Download from the OpenShift mirror
Helm CLI (helm) - See the Helm installation guide
HyperShift CLI 
```bash
# Instructions to install HyperShift CLI
git clone https://github.com/openshift/hypershift.git
cd hypershift
make build
sudo install -m 0755 bin/hypershift /usr/local/bin/hypershift
# Verify the installation 
hypershift --help
```
A modern internet browser for accessing the OpenShift web console.
### 2.1.2 Control Plane Nodes (3 Nodes)
These nodes form the control plane of the management cluster.
Form Factor: Can be virtual machines or physical servers.
Memory: 60GB Memory
CPU: 16 vCPUs (Intel/AMD x86_64)
Storage: 
Disk of 120 GB NVMe/SSD storage
An additional disk of 80GB 
Needed for OpenShift LVM Storage, which is configured in a later step.
Networking: 1x 1GbE network interface.
Note: DPUs must not be installed
### 2.1.3 Worker Nodes (2 Nodes)
The physical x86 servers which host the NVIDIA BlueField-3 DPUs and act as worker nodes for the management cluster. For the purpose of this document we used two physical servers.

Memory: 256GB RAM 
CPU: 16 cores (Intel/AMD x86_64)
Storage: 
A minimum of 500 GB NVMe/SSD storage for the base operating system.
DPU Slot: Each server can have multiple DPUs but only one  NVIDIA BlueField-3 DPU can be provisioned.
BIOS Settings:
SR-IOV must be enabled.
In-Band Manageability Interface must be enabled.
Note on Network Configuration: As part of the installation process, a Linux bridge named "br-dpu" will be automatically created on the worker node's physical management port via a MachineConfig Custom Resource to facilitate control-plane traffic from the DPU through the host server.
### 2.1.4 NVIDIA BlueField-3 DPUs (One per Worker Node)
Model: BlueField-3
Memory: 32GB
Dual-port DPUs with 32GB requires external power connection to the x86 server
Networking: Dual 200GbE ports per DPU. Both ports must be connected to the high-speed switch for ECMP routing.
Management: The out-of-band management port is not used in this configuration.
Operating System: The DPUs will be provisioned with a BlueField Bootstream File (BFB) containing a Red Hat Enterprise Linux CoreOS (RHCOS) base image, DOCA runtime, drivers, and firmware.
## 2.2 Network Infrastructure
Switches:
Management Switch: Provides 1GbE connectivity for the control plane and worker node management interfaces.
High-Speed Switch: An NVIDIA SN3700 or similar switch providing 2x 200GbE connectivity per DPU.
Connectivity:
All nodes have full internet access - both from the host out-of-band and DPU high speed interfaces.
The management network and the high-speed DPU (VTEP CIDR) network must be routable to each other.
A Virtual IP (VIP) from the management subnet must be reserved for Hosted DPU Cluster's Control-Plane services.
The Virtual IP Address used for DPU Cluster must have a DNS A Record.
MTU Configuration:
For optimized performance, all environment components—platform, nodes, interfaces, and network hardware must support jumbo frames.
This configuration is set during deployment and cannot be altered later.
When using VMs for the OCP cluster, set the MTU on the bridge of the hypervisor that the VMs are using.
Reference: For detailed network topology, interface names, and bridge configurations, refer to the RDG for DPF with OVN-Kubernetes and HBN Services, specifically the "Solution Design" and "Node and Switch Definitions" sections.

## 2.3 Software Requirements
OpenShift Version: Red Hat OpenShift Container Platform 4.22
OpenShift CLI (oc) Version: 4.22
HyperShift Hosted OpenShift Cluster Version: 4.22
NVIDIA DPF (Doca Platform Framework) Operator Version: v26.4.0
dpf-hcp-provisioner-operator Version: 0.1.0
RHCOS BFB Version: 4.22 (DOCA 3.4)
## 2.4 DNS, Access, Storage, and Security
Cluster Privileges: cluster-admin privileges are required for the management cluster.
NFS Storage: NFS share (or equivalent ReadWriteMany storage) with a dedicated folder and Read/Write permissions from the Management Network is required to store the downloaded BFB image.
DPU UEFI Secure Boot: Secure Boot must be disabled in the DPU UEFI.
For instructions please use the official NVIDIA guide for disabling Secure Boot
## 2.5 Additional Guidance

- The management cluster uses the standard OVNKubernetes network type. No custom network type or custom OVN Helm chart installation is required for the management cluster itself.
- MTU settings should be planned before deployment and applied consistently across the entire network path. The recommended MTU for high-performance deployments is 9000 (jumbo frames).
- The number of VFs per PF should be planned based on workload requirements. The default configuration allocates 46 VFs on PF0.
- The dpf-hcp-provisioner-operator automates MetalLB IPAddressPool and L2Advertisement configuration. Do not create these resources manually.
- DPU CSR approval on the hosted cluster is automated by the dpf-hcp-provisioner-operator. Only management cluster worker node CSRs need manual approval.

---

# Chapter 3: Management Cluster Setup
## 3.1 Overview 
The management cluster is a standard OpenShift v4.22 cluster installed using Red Hat's Assisted Installer.
This cluster will host the DPF operators and HyperShift control plane for managing the hosted cluster on DPUs.
## 3.2 Cluster Installation Using Assisted Installer 
### 3.2.1 Cluster Installation
Create a cluster (control-plane only) at https://console.redhat.com/openshift/create
Select "Datacenter" type -> Assisted Installer


Configure Jumbo MTU for each one of the control plane nodes
Under "Hosts' network configuration" in Assisted Installer wizard, select "Static IP, bridges, and bonds"
Set the "Static network configurations" section per node according to the following template (use the relevant MAC address and interface-name for each node):
```yaml
interfaces:
  - ipv4:
      dhcp: true
      enabled: true
    mac-address: <xx:xx:xx:xx:xx:xx>
    mtu: 9000
    name: <interface-name>
    state: up
    type: ethernet
```
Notes:
Alternatively, Jumbo MTU allocation can be configured on the DHCP server allocating IPs to the control plane nodes
In case VMs are used for control-plane nodes, Jumbo MTU should be set on the bridge of the hypervisor used by the VMs.
Make sure the switch ports that connect the cluster's control-plane nodes are set to handle jumbo frames.
Select the following operators to install with the cluster:
Storage
Logical Volume Manager Storage  
Platform Operations & Lifecycle
MultiCluster engine (Used to deploy Hosted Control Plane Operator)
Scheduling
Node Feature Discovery
Add hosts to the cluster
Control plane nodes only
After the installation is finished -> download the KUBECONFIG and save it as a file. i.e mgmt-kubeconfig

### 3.2.2 Cluster State Verification 
Run the following commands to verify the cluster is up:
```bash
# Set KUBECONFIG environment variable
$ export KUBECONFIG=mgmt-kubeconfig
# Verify cluster health
# All nodes should be Ready
$ oc get nodes
NAME STATUS ROLES AGE VERSION
master-0 Ready control-plane,worker 10m v1.35.0
master-1 Ready control-plane,worker 10m v1.35.0
master-2 Ready control-plane,worker 10m v1.35.0
```

---

# Chapter 4: Environment Setup
## 4.1 Worker Nodes Pre-Configuration

In this step, a MachineConfig resource for worker nodes is created. Note that at this stage of the installation, there are no worker nodes in the management cluster yet. The MachineConfig will be stored in the cluster's configuration and will be automatically applied by the Machine Config Operator (MCO) when worker nodes are added to the cluster. Once added, the MCO will apply and reboot the worker nodes to ensure all configurations take effect.

## 4.1 Worker Node Configuration

### 4.1.1 Worker MachineConfig Resources
The described MachineConfig resource performs several configuration tasks required by DPF:
**Bridge Configuration**: Creates a br-dpu bridge interface that enables communication between the DPU and the hosted cluster control plane running on the management cluster. For more information refer to DPF Operator Prerequisites.

**Key Features**:
- Bridge port configuration - Enslaves worker node management interface to br-dpu bridge
- Automatic interface detection - No manual configuration required
- Network readiness validation - Waits for proper network setup
- Idempotent operation - Safe to run multiple times
- Jumbo Frame MTU - Configures 9000 MTU for optimal performance

**OVS Service Management**: Disables OpenShift's default OVS services on x86 worker nodes. This is required for OVN-Kubernetes DPU Host mode operation, where networking functions are offloaded to the DPU rather than running on the host CPU.

**IP Rules Configuration**: Sets routing rules required for pod-to-host control-plane traffic

Create a MachineConfigPool for workers with DPU:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: worker-dpu
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker, worker-dpu]}
  maxUnavailable: 1
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker-dpu: ""
  paused: false
```

Create The MachineConfig Resource: 
```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
 labels:
   machineconfiguration.openshift.io/role: worker-dpu
 name: dpu-worker-configuration
spec:
 config:
   ignition:
     version: 3.2.0
   storage:
     files:
       - contents:
           source: data:text/plain;charset=utf-8;base64,<BRIDGE_SCRIPT_BASE64>
         mode: 0755
         overwrite: true
         path: /usr/local/bin/apply-nmstate-bridge.sh
       - contents:
           source: data:text/plain;charset=utf-8;base64,<ROUTING_SCRIPT_BASE64>
         mode: 0755
         overwrite: true
         path: /usr/local/bin/configure-p0-routing.sh
       - contents:
           source: data:text/plain;charset=utf-8;base64,<NETWORKMANAGER_CONFIG_BASE64>
         mode: 0644
         overwrite: true
         path: "/etc/NetworkManager/conf.d/unmanage-ovnk-interface.conf"
   systemd:
     units:
       - contents: |
           [Unit]
           Description=Apply NMState bridge configuration
           After=network.target NetworkManager.service
           Wants=NetworkManager.service
          
           [Service]
           Type=oneshot
           ExecStart=/usr/local/bin/apply-nmstate-bridge.sh 9000
           RemainAfterExit=yes
          
           [Install]
           WantedBy=multi-user.target
         enabled: true
         name: nmstate-bridge.service
       - name: ovs-configuration.service
         enabled: false
       - name: openvswitch.service
         enabled: false
         mask: true
       - name: wait-for-br-ex-up.service
         enabled: false
       - name: p0-routing.service
         enabled: true
         contents: |
           [Unit]
           Description=Configure p0 interface routing
           After=kubelet.service network-online.target
           Wants=network-online.target
          
           [Service]
           Type=oneshot
           ExecStart=/usr/local/bin/configure-p0-routing.sh
           RemainAfterExit=yes
           StandardOutput=journal
           StandardError=journal
          
           [Install]
           WantedBy=multi-user.target
```

**Procedure to create the MachineConfig with base64-encoded scripts:**

1. Create the script files with the content shown in section 4.1.2:

   ```bash
   # Create the bridge configuration script
   cat > apply-nmstate-bridge.sh << 'EOF'
   #!/bin/bash
   set -e

   BRIDGE_NAME="br-dpu"
   IP_HINT_FILE="/run/nodeip-configuration/primary-ip"
   TARGET_MTU="$1"
   NODE_IP=""

   read_node_ip() {
       if [[ ! -f "$IP_HINT_FILE" ]]; then
           echo "ERROR: IP hint file not found: $IP_HINT_FILE" >&2
           return 1
       fi

       NODE_IP=$(tr -d '[:space:]' < "$IP_HINT_FILE")

       if [[ -z "$NODE_IP" ]]; then
           echo "ERROR: IP hint file is empty: $IP_HINT_FILE" >&2
           return 1
       fi

       echo "INFO: Node IP from hint file: $NODE_IP"
   }

   wait_for_bridge_ip() {
       local bridge="$1"
       local timeout=120
       local interval=2
       local elapsed=0

       echo "INFO: Waiting up to ${timeout}s for $bridge to acquire $NODE_IP..."
       while (( elapsed < timeout )); do
           if ip -o addr show dev "$bridge" | grep -qw "$NODE_IP"; then
               echo "INFO: $bridge has $NODE_IP."
               ip addr show dev "$bridge"
               return 0
           fi
           sleep "$interval"
           elapsed=$(( elapsed + interval ))
       done

       echo "ERROR: $bridge did not acquire $NODE_IP within ${timeout}s." >&2
       return 1
   }

   set_bridge_rp_filter_loose() {
       local bridge="$1"
       echo "INFO: Setting rp_filter=2 (loose mode) on $bridge"
       sysctl -w "net.ipv4.conf.${bridge}.rp_filter=2"
   }

   validate_bridge_exists() {
       if ip link show "$BRIDGE_NAME" &> /dev/null; then
           echo "INFO: Bridge '$BRIDGE_NAME' already exists, waiting for IP..."
           wait_for_bridge_ip "$BRIDGE_NAME"
           set_bridge_rp_filter_loose "$BRIDGE_NAME"
           exit 0
       fi
   }

   get_nodeip_hint_interface() {
       local iface
       iface=$(ip -j addr | jq -r --arg ip "$NODE_IP" --arg br "$BRIDGE_NAME" \
           'first(.[] | select(any(.addr_info[]; .local==$ip) and .ifname!=$br)) | .ifname')

       if [[ -z "${iface}" || "${iface}" == "null" ]]; then
           echo "ERROR: No interface found with IP $NODE_IP" >&2
           return 1
       fi

       echo "${iface}"
   }

   apply_linux_bridge() {
       local iface="$1"
       local bridge="$BRIDGE_NAME"
       local mtu_arg="$2"

       if [ -z "$iface" ]; then
           echo "ERROR: No physical interface matches the Node IP in $IP_HINT_FILE." >&2
           exit 1
       fi

       echo "INFO: Target interface: $iface"
       echo "INFO: MTU policy: ${mtu_arg:+Set to $mtu_arg (user override)}${mtu_arg:-Inherit from physical interface}"

       local routes_json
       routes_json=$(nmstatectl show --json | jq -c --arg phys "$iface" \
           '[.routes.config // [] | .[] | select(.["next-hop-interface"] == $phys)]')

       echo "INFO: Generating NMState desired state..."
       nmstatectl show "$iface" --json | jq \
           --arg br "$bridge" \
           --arg phys "$iface" \
           --arg mtu_val "$mtu_arg" \
           --argjson phys_routes "$routes_json" \
       '
       .interfaces[0] as $p |
       (if $mtu_val != "" then {"mtu": ($mtu_val | tonumber)} else {} end) as $mtu_obj |
       {
           "interfaces": [
               ({
                   "name": $br,
                   "type": "linux-bridge",
                   "state": "up",
                   "mac-address": $p."mac-address",
                   "ipv4": ($p.ipv4 | del(.forwarding)),
                   "ipv6": ($p.ipv6 | del(.forwarding)),
                   "bridge": {
                       "options": { "stp": { "enabled": false } },
                       "port": [{ "name": $phys }]
                   }
               } + $mtu_obj),
               ({
                   "name": $phys,
                   "type": $p.type,
                   "state": "up",
                   "ipv4": { "enabled": false },
                   "ipv6": { "enabled": false }
               } + $mtu_obj
                 + if $p["link-aggregation"] then
                       { "link-aggregation": $p["link-aggregation"] }
                   else {} end)
           ]
       }
       + if ($phys_routes | length) > 0 then
           { "routes": { "config": [$phys_routes[] | .["next-hop-interface"] = $br] } }
         else {} end
       ' > /tmp/br-dpu-config.yml

       echo "--- Generated NMState desired state ---"
       cat /tmp/br-dpu-config.yml
       echo "---------------------------------------"

       echo "INFO: Applying configuration via nmstatectl..."
       if nmstatectl apply /tmp/br-dpu-config.yml; then
           echo "SUCCESS: Bridge $bridge created successfully."
           wait_for_bridge_ip "$bridge"
           ip addr show "$bridge"

           set_bridge_rp_filter_loose "$bridge"
       else
           echo "ERROR: Failed to apply NMState configuration." >&2
           rm -f /tmp/br-dpu-config.yml
           exit 1
       fi

       rm -f /tmp/br-dpu-config.yml
   }

   # --- Main ---
   read_node_ip
   validate_bridge_exists
   SELECTED_IFACE=$(get_nodeip_hint_interface)
   apply_linux_bridge "$SELECTED_IFACE" "$TARGET_MTU"
   EOF

   # Create the P0 routing script
   cat > configure-p0-routing.sh << 'EOF'
   #!/bin/bash
   set -e

   # Long-running service that ensures routing table 100 stays configured for
   # OVN-K traffic via br-dpu. Continuously monitors and re-applies rules/routes
   # in case they are removed (e.g. after NMState reconfiguration).

   CHECK_INTERVAL=2
   RECONCILE_INTERVAL=60
   PRIMARY_IP_FILE="/run/nodeip-configuration/primary-ip"

   echo "Waiting for primary IP file to determine IP version..."

   while [ ! -f "$PRIMARY_IP_FILE" ] || [ ! -s "$PRIMARY_IP_FILE" ]; do
       sleep $CHECK_INTERVAL
   done

   br_dpu_ip=$(tr -d '[:space:]' < "$PRIMARY_IP_FILE")
   echo "Using br-dpu IP from $PRIMARY_IP_FILE: $br_dpu_ip"

   if [[ "$br_dpu_ip" =~ : ]]; then
       IP_VERSION="6"
       IP_FLAG="-6"
       PREFIX_LEN="128"
       LINK_LOCAL_PATTERN="^fe80:"
       echo "Detected IPv6 configuration"
   else
       IP_VERSION="4"
       IP_FLAG="-4"
       PREFIX_LEN="32"
       LINK_LOCAL_PATTERN="^169[.]254"
       echo "Detected IPv4 configuration"
   fi

   ensure_rule() {
       if ip $IP_FLAG -j rule list | jq -e --arg src "$br_dpu_ip" '.[] | select(.src == $src and .table == "100")' > /dev/null 2>&1; then
           return 0
       fi
       echo "Adding rule: from $br_dpu_ip/$PREFIX_LEN lookup 100"
       ip $IP_FLAG rule add from $br_dpu_ip/$PREFIX_LEN lookup 100
   }

   ensure_route() {
       local dst="$1"; shift
       if ip $IP_FLAG -j route show table 100 | jq -e --arg dst "$dst" '.[] | select(.dst == $dst)' > /dev/null 2>&1; then
           return 0
       fi
       echo "Adding route: $dst $*  table 100"
       ip $IP_FLAG route add $dst "$@" table 100
   }

   configure_routing() {
       local ovnk_iface="$1"
       local ovnk_ip="$2"

       local br_dpu_network
       br_dpu_network=$(ip $IP_FLAG -j route show dev br-dpu | jq -r '.[] | select(.protocol == "kernel") | .dst' | head -n1)
       if [ -z "$br_dpu_network" ]; then
           echo "Warning: Could not find br-dpu network, will retry"
           return 1
       fi

       local br_dpu_gateway
       br_dpu_gateway=$(ip $IP_FLAG -j route | jq -r '.[] | select(.dst == "default" and .dev == "br-dpu") | .gateway' | head -n1)
       if [ -z "$br_dpu_gateway" ]; then
           echo "Warning: Could not find gateway for br-dpu, will retry"
           return 1
       fi

       local ovnk_subnet
       ovnk_subnet=$(ip $IP_FLAG -j route | jq --arg dev "$ovnk_iface" --arg pattern "$LINK_LOCAL_PATTERN" -r '
         .[] | select(
           .dev == $dev
           and .dst != null
           and .dst != "default"
           and (.dst | test($pattern) | not)
           and .gateway == null
         ) | .dst' | head -n1)
       if [ -z "$ovnk_subnet" ]; then
           echo "Warning: Could not find subnet for $ovnk_iface, will retry"
           return 1
       fi

       local br_dpu_metric
       br_dpu_metric=$(ip $IP_FLAG -j route show dev br-dpu | jq -r '.[] | select(.protocol == "kernel") | .metric // 425' | head -n1)

       ensure_rule
       ensure_route "$ovnk_subnet" via "$br_dpu_gateway"
       ensure_route "$br_dpu_network" dev br-dpu proto kernel scope link src "$br_dpu_ip" metric "$br_dpu_metric"
       return 0
   }

   echo "Waiting for OVN-K interface (with link-local address) to get an IP address..."

   configured=false
   while true; do
       ovnk_ifaces=$(ip -j addr show | jq --arg pattern "$LINK_LOCAL_PATTERN" -r '.[] | select(.addr_info[]? | .local | test($pattern)) | .ifname' | sort -u)

       for ovnk_iface in $ovnk_ifaces; do
           ovnk_ip=$(ip $IP_FLAG -j addr show "$ovnk_iface" | jq --arg pattern "$LINK_LOCAL_PATTERN" -r '.[] | .addr_info[]? | select(.local | test($pattern) | not) | .local' | head -n1)

           if [ -n "$ovnk_ip" ]; then
               if [ "$configured" = "false" ]; then
                   echo "Found OVN-K interface: $ovnk_iface with IPv${IP_VERSION}: $ovnk_ip"
               fi
               if configure_routing "$ovnk_iface" "$ovnk_ip"; then
                   if [ "$configured" = "false" ]; then
                       echo "Routing configuration completed, entering reconcile loop"
                       configured=true
                   fi
               fi
               break
           fi
       done

       if [ "$configured" = "true" ]; then
           sleep $RECONCILE_INTERVAL
       else
           sleep $CHECK_INTERVAL
       fi
   done
   EOF

   # Create NetworkManager config
   cat > unmanage-ovnk-interface.conf << 'EOF'
   [keyfile]
   unmanaged-devices=interface-name:ovn-k8s-*
   EOF
   ```

2. Encode the scripts to base64:

   ```bash
   # Generate base64 encoded versions
   BRIDGE_SCRIPT_BASE64=$(base64 -w 0 apply-nmstate-bridge.sh)
   ROUTING_SCRIPT_BASE64=$(base64 -w 0 configure-p0-routing.sh)
   NETWORKMANAGER_CONFIG_BASE64=$(base64 -w 0 unmanage-ovnk-interface.conf)
   ```

3. Create the final YAML with substituted values:

   ```bash
   # Create the MachineConfig with substituted base64 content
   envsubst << 'EOF' > dpu-worker-configuration.yaml
   apiVersion: machineconfiguration.openshift.io/v1
   kind: MachineConfig
   metadata:
    labels:
      machineconfiguration.openshift.io/role: worker-dpu
    name: dpu-worker-configuration
   spec:
    config:
      ignition:
        version: 3.2.0
      storage:
        files:
          - contents:
              source: data:text/plain;charset=utf-8;base64,$BRIDGE_SCRIPT_BASE64
            mode: 0755
            overwrite: true
            path: /usr/local/bin/apply-nmstate-bridge.sh
          - contents:
              source: data:text/plain;charset=utf-8;base64,$ROUTING_SCRIPT_BASE64
            mode: 0755
            overwrite: true
            path: /usr/local/bin/configure-p0-routing.sh
          - contents:
              source: data:text/plain;charset=utf-8;base64,$NETWORKMANAGER_CONFIG_BASE64
            mode: 0644
            overwrite: true
            path: "/etc/NetworkManager/conf.d/unmanage-ovnk-interface.conf"
      systemd:
        units:
          - contents: |
              [Unit]
              Description=Apply NMState bridge configuration
              After=network.target NetworkManager.service nodeip-configuration.service nmstate.service
              Before=crio.service kubelet.service

              [Service]
              Type=oneshot
              ExecStart=/usr/local/bin/apply-nmstate-bridge.sh \$NODES_MTU
              RemainAfterExit=yes
              TimeoutStartSec=150s
              Restart=on-failure
              RestartSec=10

              [Install]
              WantedBy=multi-user.target
            enabled: true
            name: nmstate-bridge.service
          - name: ovs-configuration.service
            enabled: false
          - name: openvswitch.service
            enabled: false
            mask: true
          - name: wait-for-br-ex-up.service
            enabled: false
          - name: p0-routing.service
            enabled: true
            contents: |
              [Unit]
              Description=Configure and maintain p0 interface routing
              After=kubelet.service network-online.target nmstate-bridge.service
              Wants=network-online.target

              [Service]
              Type=simple
              ExecStart=/usr/local/bin/configure-p0-routing.sh
              StandardOutput=journal
              StandardError=journal
              Restart=always
              RestartSec=10

              [Install]
              WantedBy=multi-user.target
   EOF
   ```

4. Apply the configuration:

   ```bash
   export NODES_MTU=1500  # Set to 9000 for jumbo frames or 1500 for standard MTU

   oc apply -f worker-dpu-mcp.yaml
   # Expected output
   machineconfigpool.machineconfiguration.openshift.io/worker-dpu created

   oc apply -f dpu-worker-configuration.yaml
   # Expected output
   machineconfig.machineconfiguration.openshift.io/dpu-worker-configuration created
   ```

### 4.1.2 MachineConfig Decoded Scripts (For Information Only)
The MachineConfig resource applied in the previous step includes a few encoded scripts. 
Here is a decoded description of the scripts:

**A script for detecting the default network interface and creating the br-dpu bridge:**

```bash
#!/bin/bash
set -e

BRIDGE_NAME="br-dpu"
IP_HINT_FILE="/run/nodeip-configuration/primary-ip"
TARGET_MTU="$1"
NODE_IP=""

read_node_ip() {
    if [[ ! -f "$IP_HINT_FILE" ]]; then
        echo "ERROR: IP hint file not found: $IP_HINT_FILE" >&2
        return 1
    fi

    NODE_IP=$(tr -d '[:space:]' < "$IP_HINT_FILE")

    if [[ -z "$NODE_IP" ]]; then
        echo "ERROR: IP hint file is empty: $IP_HINT_FILE" >&2
        return 1
    fi

    echo "INFO: Node IP from hint file: $NODE_IP"
}

wait_for_bridge_ip() {
    local bridge="$1"
    local timeout=120
    local interval=2
    local elapsed=0

    echo "INFO: Waiting up to ${timeout}s for $bridge to acquire $NODE_IP..."
    while (( elapsed < timeout )); do
        if ip -o addr show dev "$bridge" | grep -qw "$NODE_IP"; then
            echo "INFO: $bridge has $NODE_IP."
            ip addr show dev "$bridge"
            return 0
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    echo "ERROR: $bridge did not acquire $NODE_IP within ${timeout}s." >&2
    return 1
}

set_bridge_rp_filter_loose() {
    local bridge="$1"
    echo "INFO: Setting rp_filter=2 (loose mode) on $bridge"
    sysctl -w "net.ipv4.conf.${bridge}.rp_filter=2"
}

validate_bridge_exists() {
    if ip link show "$BRIDGE_NAME" &> /dev/null; then
        echo "INFO: Bridge '$BRIDGE_NAME' already exists, waiting for IP..."
        wait_for_bridge_ip "$BRIDGE_NAME"
        set_bridge_rp_filter_loose "$BRIDGE_NAME"
        exit 0
    fi
}

get_nodeip_hint_interface() {
    local iface
    iface=$(ip -j addr | jq -r --arg ip "$NODE_IP" --arg br "$BRIDGE_NAME" \
        'first(.[] | select(any(.addr_info[]; .local==$ip) and .ifname!=$br)) | .ifname')

    if [[ -z "${iface}" || "${iface}" == "null" ]]; then
        echo "ERROR: No interface found with IP $NODE_IP" >&2
        return 1
    fi

    echo "${iface}"
}

apply_linux_bridge() {
    local iface="$1"
    local bridge="$BRIDGE_NAME"
    local mtu_arg="$2"

    if [ -z "$iface" ]; then
        echo "ERROR: No physical interface matches the Node IP in $IP_HINT_FILE." >&2
        exit 1
    fi

    echo "INFO: Target interface: $iface"
    echo "INFO: MTU policy: ${mtu_arg:+Set to $mtu_arg (user override)}${mtu_arg:-Inherit from physical interface}"

    local routes_json
    routes_json=$(nmstatectl show --json | jq -c --arg phys "$iface" \
        '[.routes.config // [] | .[] | select(.["next-hop-interface"] == $phys)]')

    echo "INFO: Generating NMState desired state..."
    nmstatectl show "$iface" --json | jq \
        --arg br "$bridge" \
        --arg phys "$iface" \
        --arg mtu_val "$mtu_arg" \
        --argjson phys_routes "$routes_json" \
    '
    .interfaces[0] as $p |
    (if $mtu_val != "" then {"mtu": ($mtu_val | tonumber)} else {} end) as $mtu_obj |
    {
        "interfaces": [
            ({
                "name": $br,
                "type": "linux-bridge",
                "state": "up",
                "mac-address": $p."mac-address",
                "ipv4": ($p.ipv4 | del(.forwarding)),
                "ipv6": ($p.ipv6 | del(.forwarding)),
                "bridge": {
                    "options": { "stp": { "enabled": false } },
                    "port": [{ "name": $phys }]
                }
            } + $mtu_obj),
            ({
                "name": $phys,
                "type": $p.type,
                "state": "up",
                "ipv4": { "enabled": false },
                "ipv6": { "enabled": false }
            } + $mtu_obj
              + if $p["link-aggregation"] then
                    { "link-aggregation": $p["link-aggregation"] }
                else {} end)
        ]
    }
    + if ($phys_routes | length) > 0 then
        { "routes": { "config": [$phys_routes[] | .["next-hop-interface"] = $br] } }
      else {} end
    ' > /tmp/br-dpu-config.yml

    echo "--- Generated NMState desired state ---"
    cat /tmp/br-dpu-config.yml
    echo "---------------------------------------"

    echo "INFO: Applying configuration via nmstatectl..."
    if nmstatectl apply /tmp/br-dpu-config.yml; then
        echo "SUCCESS: Bridge $bridge created successfully."
        wait_for_bridge_ip "$bridge"
        ip addr show "$bridge"

        set_bridge_rp_filter_loose "$bridge"
    else
        echo "ERROR: Failed to apply NMState configuration." >&2
        rm -f /tmp/br-dpu-config.yml
        exit 1
    fi

    rm -f /tmp/br-dpu-config.yml
}

# --- Main ---
read_node_ip
validate_bridge_exists
SELECTED_IFACE=$(get_nodeip_hint_interface)
apply_linux_bridge "$SELECTED_IFACE" "$TARGET_MTU"
```

**A long-running service that ensures routing table 100 stays configured for OVN-K traffic via br-dpu. Continuously monitors and re-applies rules/routes in case they are removed (configure-p0-routing.sh):**

```bash
#!/bin/bash
set -e

# Long-running service that ensures routing table 100 stays configured for
# OVN-K traffic via br-dpu. Continuously monitors and re-applies rules/routes
# in case they are removed (e.g. after NMState reconfiguration).

CHECK_INTERVAL=2
RECONCILE_INTERVAL=60
PRIMARY_IP_FILE="/run/nodeip-configuration/primary-ip"

echo "Waiting for primary IP file to determine IP version..."

while [ ! -f "$PRIMARY_IP_FILE" ] || [ ! -s "$PRIMARY_IP_FILE" ]; do
    sleep $CHECK_INTERVAL
done

br_dpu_ip=$(tr -d '[:space:]' < "$PRIMARY_IP_FILE")
echo "Using br-dpu IP from $PRIMARY_IP_FILE: $br_dpu_ip"

if [[ "$br_dpu_ip" =~ : ]]; then
    IP_VERSION="6"
    IP_FLAG="-6"
    PREFIX_LEN="128"
    LINK_LOCAL_PATTERN="^fe80:"
    echo "Detected IPv6 configuration"
else
    IP_VERSION="4"
    IP_FLAG="-4"
    PREFIX_LEN="32"
    LINK_LOCAL_PATTERN="^169[.]254"
    echo "Detected IPv4 configuration"
fi

ensure_rule() {
    if ip $IP_FLAG -j rule list | jq -e --arg src "$br_dpu_ip" '.[] | select(.src == $src and .table == "100")' > /dev/null 2>&1; then
        return 0
    fi
    echo "Adding rule: from $br_dpu_ip/$PREFIX_LEN lookup 100"
    ip $IP_FLAG rule add from $br_dpu_ip/$PREFIX_LEN lookup 100
}

ensure_route() {
    local dst="$1"; shift
    if ip $IP_FLAG -j route show table 100 | jq -e --arg dst "$dst" '.[] | select(.dst == $dst)' > /dev/null 2>&1; then
        return 0
    fi
    echo "Adding route: $dst $*  table 100"
    ip $IP_FLAG route add $dst "$@" table 100
}

configure_routing() {
    local ovnk_iface="$1"
    local ovnk_ip="$2"

    local br_dpu_network
    br_dpu_network=$(ip $IP_FLAG -j route show dev br-dpu | jq -r '.[] | select(.protocol == "kernel") | .dst' | head -n1)
    if [ -z "$br_dpu_network" ]; then
        echo "Warning: Could not find br-dpu network, will retry"
        return 1
    fi

    local br_dpu_gateway
    br_dpu_gateway=$(ip $IP_FLAG -j route | jq -r '.[] | select(.dst == "default" and .dev == "br-dpu") | .gateway' | head -n1)
    if [ -z "$br_dpu_gateway" ]; then
        echo "Warning: Could not find gateway for br-dpu, will retry"
        return 1
    fi

    local ovnk_subnet
    ovnk_subnet=$(ip $IP_FLAG -j route | jq --arg dev "$ovnk_iface" --arg pattern "$LINK_LOCAL_PATTERN" -r '
      .[] | select(
        .dev == $dev
        and .dst != null
        and .dst != "default"
        and (.dst | test($pattern) | not)
        and .gateway == null
      ) | .dst' | head -n1)
    if [ -z "$ovnk_subnet" ]; then
        echo "Warning: Could not find subnet for $ovnk_iface, will retry"
        return 1
    fi

    local br_dpu_metric
    br_dpu_metric=$(ip $IP_FLAG -j route show dev br-dpu | jq -r '.[] | select(.protocol == "kernel") | .metric // 425' | head -n1)

    ensure_rule
    ensure_route "$ovnk_subnet" via "$br_dpu_gateway"
    ensure_route "$br_dpu_network" dev br-dpu proto kernel scope link src "$br_dpu_ip" metric "$br_dpu_metric"
    return 0
}

echo "Waiting for OVN-K interface (with link-local address) to get an IP address..."

configured=false
while true; do
    ovnk_ifaces=$(ip -j addr show | jq --arg pattern "$LINK_LOCAL_PATTERN" -r '.[] | select(.addr_info[]? | .local | test($pattern)) | .ifname' | sort -u)

    for ovnk_iface in $ovnk_ifaces; do
        ovnk_ip=$(ip $IP_FLAG -j addr show "$ovnk_iface" | jq --arg pattern "$LINK_LOCAL_PATTERN" -r '.[] | .addr_info[]? | select(.local | test($pattern) | not) | .local' | head -n1)

        if [ -n "$ovnk_ip" ]; then
            if [ "$configured" = "false" ]; then
                echo "Found OVN-K interface: $ovnk_iface with IPv${IP_VERSION}: $ovnk_ip"
            fi
            if configure_routing "$ovnk_iface" "$ovnk_ip"; then
                if [ "$configured" = "false" ]; then
                    echo "Routing configuration completed, entering reconcile loop"
                    configured=true
                fi
            fi
            break
        fi
    done

    if [ "$configured" = "true" ]; then
        sleep $RECONCILE_INTERVAL
    else
        sleep $CHECK_INTERVAL
    fi
done
```   


## 4.2 Cluster Configuration

### 4.2.1 Custom Cluster Feature -- MutatingAdmissionPolicy

Enable the MutatingAdmissionPolicy feature gate. This is required for the OVN-Kubernetes resource injector webhook.

Patch the FeatureGate resource:

```bash
$ oc patch featuregate/cluster --type=merge --patch='{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["MutatingAdmissionPolicy"]}}}'
```

# Expected output:
```
featuregate.config.openshift.io/cluster patched
```

**Warning**: Setting `featureSet: CustomNoUpgrade` prevents automated cluster upgrades. This is required for DPF but must be accounted for in your upgrade planning.

Verify the feature gate is applied:

```bash
$ oc get featuregate/cluster -o jsonpath='{.spec.featureSet}'
```

# Expected output:
```
CustomNoUpgrade
```

### 4.2.2 Control Plane Node Patching

The MutatingAdmissionPolicy injects SR-IOV resource requests into pods that use the OVN-Kubernetes network attachment. Some system pods may need to use this network attachment while running on control plane nodes.
All control plane nodes must be patched to include resource capacity and allocatable values for the SR-IOV VF resources.
The patch allows these pods to be scheduled on control plane nodes by satisfying the scheduler's resource requirements (actual device allocation only occurs on worker nodes with physical DPU hardware).

Apply the configuration:
```bash
$ for node in $(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do oc patch node "$node" --subresource=status --type=json -p="[{\"op\": \"add\", \"path\": \"/status/capacity/openshift.io~1bf3-p0-vfs\", \"value\": \"10000\"},{\"op\": \"add\", \"path\": \"/status/allocatable/openshift.io~1bf3-p0-vfs\", \"value\": \"10000\"}]"; done
```

# Expected output 
```
node/master-0 patched
node/master-1 patched
node/master-2 patched
```
Verify the configuration was applied:
```bash
$ oc get nodes -l node-role.kubernetes.io/control-plane -o json | \
  jq '.items[] | {name: .metadata.name, capacity: .status.capacity."openshift.io/bf3-p0-vfs", allocatable: .status.allocatable."openshift.io/bf3-p0-vfs"}'
```

# Example output:
```json
{
  "name": "master-0",
  "capacity": "10k",
  "allocatable": "10k"
}
{
  "name": "master-1",
  "capacity": "10k",
  "allocatable": "10k"
}
{
  "name": "master-2",
  "capacity": "10k",
  "allocatable": "10k"
}
```

**Note**: This patch only applies to existing control plane nodes at the time this script runs. Any new control plane nodes added to the cluster will need to be patched as well.

### 4.2.1 Create DPF Namespace

```bash
oc create namespace dpf-operator-system

# Expected output 
namespace/dpf-operator-system created
```

### 4.2.3 Create DPF Namespace

Create the `dpf-operator-system` namespace with the required security labels. The `privileged` pod security labels are required because DPF components need host-level access for networking operations.

Create the resource file:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dpf-operator-system
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: "privileged"
    pod-security.kubernetes.io/audit: "privileged"
    pod-security.kubernetes.io/warn: "privileged"
    cert-manager.io/disable-validation: "true"
```

Apply the file:

```bash
$ oc apply -f dpf-operator-ns.yaml
```

# Expected output:
```
namespace/dpf-operator-system created
```

## 4.3 Operators Installation

Install the prerequisite operators on the management cluster. The operators can be installed in any order, but all must be installed and running before proceeding to the DPF Operator installation.

### 4.3.1 Cert Manager Operator

Cert-Manager automates certificate lifecycle management required by the DPF Operator and hosted cluster services.

Create the resource file:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator-group
  namespace: cert-manager-operator
spec:
  targetNamespaces:
    - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: openshift-operators
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Apply the file:

```bash
$ oc apply -f openshift-cert-manager.yaml
```

# Expected output:
```
namespace/cert-manager-operator created
operatorgroup.operators.coreos.com/cert-manager-operator-group created
subscription.operators.coreos.com/openshift-cert-manager-operator created
```

Verify the cert-manager pods are running:

```bash
$ oc get pods -n cert-manager
```

# Example output:
```
NAME                                      READY   STATUS    RESTARTS   AGE
cert-manager-6d87886d5c-x7kpz            1/1     Running   0          2m
cert-manager-cainjector-7b4f5b8c4-9qvnp  1/1     Running   0          2m
cert-manager-webhook-7d8f5b9b5-mz4kv     1/1     Running   0          2m
```

### 4.3.2 Node Feature Discovery Operator

NFD automatically detects hardware features on worker nodes, including DPU presence and capabilities.

Create the resource file:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nfd-operator-group
  namespace: openshift-nfd
spec:
  targetNamespaces:
    - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: "stable"
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

Apply the file:

```bash
$ oc apply -f nfd-subscription.yaml
```

# Expected output:
```
namespace/openshift-nfd created
operatorgroup.operators.coreos.com/nfd-operator-group created
subscription.operators.coreos.com/nfd created
```

Wait for the operator to become available:

```bash
$ oc wait deployment/nfd-controller-manager -n openshift-nfd \
    --for condition=Available --timeout=5m
```

# Expected output:
```
deployment.apps/nfd-controller-manager condition met
```

### 4.3.3 SR-IOV Network Operator

The SR-IOV Network Operator manages virtual function configuration on worker nodes with DPUs.

Create the resource file:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-sriov-network-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sriov-network-operators
  namespace: openshift-sriov-network-operator
spec:
  targetNamespaces:
    - openshift-sriov-network-operator
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sriov-network-operator-subscription
  namespace: openshift-sriov-network-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: sriov-network-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Apply the file:

```bash
$ oc apply -f sriov-op-dpf.yaml
```

# Expected output:
```
namespace/openshift-sriov-network-operator created
operatorgroup.operators.coreos.com/sriov-network-operators created
subscription.operators.coreos.com/sriov-network-operator-subscription created
```

Verify the operator is running:

```bash
$ oc get csv -n openshift-sriov-network-operator | grep sriov
```

# Example output:
```
sriov-network-operator.v4.22.0   SR-IOV Network Operator   Succeeded
```

### 4.3.4 MetalLB Operator

MetalLB provides load balancer functionality for bare-metal clusters. It is required for the hosted cluster API endpoint. Install the operator and create the MetalLB instance.

**Note**: The IPAddressPool and L2Advertisement resources are managed automatically by the dpf-hcp-provisioner-operator. Do not create them manually.

Create the resource file:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator-group
  namespace: metallb-system
spec:
  targetNamespaces:
    - metallb-system
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  channel: stable
  name: metallb-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

Apply the file:

```bash
$ oc apply -f metallb-operator.yaml
```

# Expected output:
```
namespace/metallb-system created
operatorgroup.operators.coreos.com/metallb-operator-group created
subscription.operators.coreos.com/metallb-operator created
```

Create the MetalLB instance:

```bash
$ cat <<EOF | oc apply -f -
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF
```

# Expected output:
```
metallb.metallb.io/metallb created
```

### 4.3.5 Red Hat OpenShift GitOps Operator

The GitOps Operator provides ArgoCD for managing DPU service deployments.

Create the resource file:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: "1.16"
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

Apply the file:

```bash
$ oc apply -f openshift-gitops.yaml
```

# Expected output:
```
subscription.operators.coreos.com/openshift-gitops-operator created
```

Verify the ArgoCD instance is running:

```bash
$ oc get pods -n openshift-gitops
```

# Example output:
```
NAME                                                  READY   STATUS    RESTARTS   AGE
openshift-gitops-application-controller-0              1/1     Running   0          3m
openshift-gitops-repo-server-7f9c8d7b5-x2tlh          1/1     Running   0          3m
openshift-gitops-server-5d4c8f8d4-k8n2v               1/1     Running   0          3m
```

### 4.3.6 Multicluster Engine (MCE) Operator

The MCE Operator provides the HyperShift capability required for creating the hosted DPU cluster. Install the operator, create the MultiClusterEngine instance, and enable the HyperShift addon.

Create the resource file:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: multicluster-engine
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: mce-operator-group
  namespace: multicluster-engine
spec:
  targetNamespaces:
    - multicluster-engine
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multicluster-engine
  namespace: multicluster-engine
spec:
  channel: stable-2.8
  name: multicluster-engine
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

Apply the file:

```bash
$ oc apply -f mce-operator.yaml
```

Create the MultiClusterEngine instance:

```bash
$ cat <<EOF | oc apply -f -
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine
spec: {}
EOF
```

Wait for MCE to be available:

```bash
$ oc wait multiclusterengine/multiclusterengine --for condition=Available --timeout=10m
```

Enable the HyperShift addon:

```bash
$ oc patch mce multiclusterengine --type=merge \
    -p '{"spec":{"overrides":{"components":[{"name":"hypershift","enabled":true},{"name":"hypershift-local-hosting","enabled":true}]}}}'
```

Verify HyperShift is enabled:

```bash
$ oc get pods -n hypershift | grep operator
```

# Example output:
```
operator-5b4f8d9c7-abcde    2/2     Running   0     2m
```

### 4.3.7 Maintenance Operator CRD

The Maintenance Operator CRD must be installed before the DPF Operator. The operator itself is deployed as part of the DPF Helm chart.

Apply the Maintenance Operator CRD:

```bash
$ oc apply -f maintenance-oc-crd.yaml
```

# Expected output:
```
customresourcedefinition.apiextensions.k8s.io/maintenanceoperatorconfigs.maintenance.nvidia.com created
```

## 4.4 Operator Configuration

### 4.4.1 Configure NFD Operator

Create the NFD instance and the DPU detection rule to automatically label nodes with BlueField-3 DPUs.

Create the resource file:

```yaml
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  operand:
    image: quay.io/yshnaidm/node-feature-discovery:dpf
    workerEnvs:
      - name: KUBERNETES_SERVICE_HOST
        value: $HOST_CLUSTER_API
      - name: KUBERNETES_SERVICE_PORT
        value: "6443"
  workerConfig:
    configData: |
      sources:
        pci:
          deviceClassWhitelist:
            - "0200"
            - "03"
            - "12"
            - "0207"
          deviceLabelFields:
            - "vendor"
            - "device"
            - "class"
---
apiVersion: nfd.openshift.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: dpu-detection-rule
  namespace: openshift-nfd
spec:
  rules:
    - name: "DPU-detection-rule"
      labels:
        dpu-enabled: ""
      matchFeatures:
        - feature: pci.device
          matchExpressions:
            vendor: {op: In, value: ["15b3"]}
            device: {op: In, value: ["a2d6", "a2dc"]}
```

Apply the file using the following command:
```bash
$ envsubst < nfd-instance.yaml | oc apply -f -
```

# Expected output:
```
nodefeaturediscovery.nfd.openshift.io/nfd created
nodefeaturerule.nfd.openshift.io/dpu-detection-rule created
```

Verify NFD detects DPU-equipped nodes (after worker nodes are added):

```bash
$ oc get nodes -l feature.node.kubernetes.io/dpu-enabled=true
```

# Example output:
```
NAME              STATUS   ROLES    AGE   VERSION
worker-0          Ready    worker   10m   v1.35.0
```

### 4.4.2 Configure MetalLB Operator 
Define the following hosted cluster variables used by MetalLB:
```bash
export HOSTED_CLUSTER_VIP=10.0.110.200/32 # Virtual IP for hosted DPU cluster allocated from the management cluster subnet
export HOSTED_CLUSTER_NAME="dpf-hosted" # DPU hosted cluster name
```
Note: those variables are defined as well in section 5.

Create the MetalLB resource file with the following CRs: 
MetalLB: This CR deploys the MetalLB load balancer in the cluster to provide external IP addresses for services.
IPAddressPool: This CR defines a pool of IP addresses (in this case a single VIP) that MetalLB can assign to services in the specified namespace.
L2Advertisement: This CR configures MetalLB to advertise the IP addresses from the specified pool using Layer 2 mode.
```yaml
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: openshift-operators
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-network
  namespace: openshift-operators
spec:
  addresses:
    - $HOSTED_CLUSTER_VIP  # Virtual IP for hosted DPU cluster allocated from the management cluster subnet 
  serviceAllocation:
    namespaces:
      - clusters-$HOSTED_CLUSTER_NAME # DPU hosted cluster name
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: advertise-lab-network
  namespace: openshift-operators
spec:
  ipAddressPools:
    - lab-network
```

Apply the resource file:
```bash
$ envsubst < metallb-config.yaml | oc apply -f -
```

# Expected output:
```
metallb.metallb.io/metallb created
ipaddresspool.metallb.io/lab-network created
l2advertisement.metallb.io/advertise-lab-network created
```

**Note**: When using the dpf-hcp-provisioner-operator (Chapter 5), the IPAddressPool and L2Advertisement may be managed automatically by the operator. In that case, only the MetalLB CR needs to be created manually.

### 4.4.3 Configure GitOps Operator

Grant ArgoCD the necessary permissions to manage DPF resources.

Patch the ArgoCD instance to allow cluster-scoped resource management:

```bash
$ oc patch argocd/openshift-gitops -n openshift-gitops --type=merge \
    -p '{"spec":{"server":{"insecure":true},"resourceExclusions":"- apiGroups:\n  - tekton.dev\n  clusters:\n  - \"*\"\n  kinds:\n  - TaskRun\n  - PipelineRun\n"}}'
```

Create the ArgoCD project for DPF:

```bash
$ cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: dpf
  namespace: openshift-gitops
spec:
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  destinations:
    - namespace: '*'
      server: '*'
  sourceRepos:
    - '*'
EOF
```

### 4.4.5 Configure Cluster Network Operator

Enable IP forwarding for pod networking through the Cluster Network Operator.

Patch the CNO to enable IP forwarding:

```bash
$ oc patch network.operator.openshift.io cluster --type=merge \
    -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding":"Global"}}}}}'
```

# Expected output:
```
network.operator.openshift.io/cluster patched
```

Verify the configuration:

```bash
$ oc get network.operator.openshift.io cluster \
    -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipForwarding}'
```

# Expected output:
```
Global
```

## 4.5 Custom SR-IOV Device Plugin

**Note**: The custom SR-IOV device plugin DaemonSet from previous versions has been replaced by the NodeSRIOVDevicePluginConfig resource in DPF v26.4. See section 6.5.2 for the new approach. The DPF Operator now manages SR-IOV device plugin pods automatically based on the NodeSRIOVDevicePluginConfig CRD.

---

# Chapter 5: DPF Operator Installation and Configuration

This chapter covers the installation of the DPF Operator via Helm, the creation of the DPFOperatorConfig, NodeSRIOVDevicePluginConfig, and all DPU service resources including the BFB image, DPUFlavor, service templates, service configurations, interfaces, IPAM, and the DPUDeployment.

**Important**: The DPF Operator must be installed before the dpf-hcp-provisioner-operator (Chapter 6) because the provisioner operator requires the following DPF CRDs to be available:
- DPUCluster (every DPFHCPProvisioner CR points to one and operator watches and patches it)
- DPUFlavor (fetched during ignition generation to detect DPU mode and NVConfig params)
- DPUDeployment (fetched during ignition generation to extract worker node configuration)
- DPFOperatorConfig (fetched and patched during ignition generation)

## 5.1 Environment Variables

The following environment variables are used throughout this chapter. Set these values before applying manifests.

```bash
# OpenShift Infrastructure
export CLUSTER_NAME="doca-mgmt" # Management cluster name
export BASE_DOMAIN="example.com" # Management cluster base domain
export HOST_CLUSTER_API="api.${CLUSTER_NAME}.${BASE_DOMAIN}" # Management cluster API endpoint 

# NVIDIA DPF 
export TAG="v26.4.0" # DPF operator version
export TARGETCLUSTER_API_SERVER_PORT="6443" # Management Cluster API port
export TARGETCLUSTER_NODE_CIDR=<TARGETCLUSTER_NODE_CIDR> # IP address range for hosts (e.g., 10.0.110.0/24)
export NFS_SERVER_IP=<NFS_SERVER_IP> # NFS server IP for BFB image storage (e.g., 10.0.110.253)
export NFS_BFB_PATH=<NFS_BFB_PATH> # Path for BFB in the NFS server with RW access e.g., "/"

## Network Configuration
export POD_CIDR="10.128.0.0/14" # Pod network CIDR of the Management Cluster
export SERVICE_CIDR="172.30.0.0/16" # Service network CIDR of the Management Cluster
export VTEP_CIDR=<VTEP_CIDR> # Worker OVN tunnel network range (e.g., 10.0.120.0/22)
export NUM_VFS="46" # Number of VFs to create on DPU interfaces

## Registry URLs 
export REGISTRY="https://helm.ngc.nvidia.com/nvidia/doca" # DPF operator Helm registry

## HBN Configuration
export HBN_HELM_REPO_URL="https://helm.ngc.nvidia.com/nvidia/doca" # HBN Helm chart registry
export HBN_HELM_CHART_VERSION="1.0.3" # HBN chart version
export HBN_IMAGE_REPO="nvcr.io/nvidia/doca/doca_hbn" # HBN container image repository
export HBN_IMAGE_TAG="3.2.0-doca3.2.0" # HBN container image tag

## DTS Configuration
export DTS_HELM_REPO_URL="https://helm.ngc.nvidia.com/nvidia/doca" # DTS Helm chart registry
export DTS_HELM_CHART_VERSION="1.22.1" # DTS chart version
export DTS_IMAGE="nvcr.io/nvidia/doca/doca_telemetry:1.21.5-doca3.0.0" # DTS container image

## BFB Configuration
export BFB_URL=<BFB_URL> # URL to the RHCOS-based BFB image for DPU provisioning

## OVN-Kubernetes
export OVN_TEMPLATE_CHART_URL="oci://ghcr.io/mellanox/charts"
export OVN_CHART_VERSION="v26.4.0-ocpbeta"
export OVN_KUBERNETES_IMAGE_REPO="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256"
export OVN_KUBERNETES_IMAGE_TAG="<OVN_IMAGE_SHA>" # OVN-K image SHA for your OCP version
```

Notes: 
For more information about the environment variables visit NVIDIA Official Doc
```

## 5.2 Create DPU Image Storage Objects

If using NFS storage for BFB images, create the PersistentVolume and PersistentVolumeClaim for BFB image storage.

Create the PersistentVolume:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: bfb-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteMany
  nfs:
    path: $NFS_BFB_PATH
    server: $NFS_SERVER_IP
  persistentVolumeReclaimPolicy: Retain
```

Create the PersistentVolumeClaim:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bfb-pvc
  namespace: dpf-operator-system
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
  volumeName: bfb-pv
```

Apply the files:

```bash
$ oc apply -f bfb-pv.yaml
$ oc apply -f bfb-pvc.yaml
```

# Expected output:
```
persistentvolume/bfb-pv created
persistentvolumeclaim/bfb-pvc created
```

## 5.3 Install DPF Operator

The DPF Operator is installed via Helm from the NVIDIA registry.

Create the pull secret for DPF images:

```yaml
apiVersion: v1
kind: Secret
metadata:
  labels:
    dpf.nvidia.com/image-pull-secret: ""
  name: dpf-pull-secret
  namespace: dpf-operator-system
data:
  .dockerconfigjson: <PULL_SECRET_BASE64>
type: kubernetes.io/dockerconfigjson
```

Replace `<PULL_SECRET_BASE64>` with your base64-encoded Docker config JSON containing credentials for `nvcr.io`, `ghcr.io`, and `quay.io`.

**Note**: To generate the base64-encoded value:
```bash
$ cat ~/.docker/config.json | base64 -w0
```

Apply the file:

```bash
$ oc apply -f dpf-pull-secret.yaml
```

# Expected output:
```
secret/dpf-pull-secret created
```

Create NGC Helm repository secrets for ArgoCD:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: ngc-doca-https-helm
  namespace: dpf-operator-system
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: nvstaging-doca-https
  url: https://helm.ngc.nvidia.com/nvidia/doca
  type: helm
  username: $oauthtoken
  password: <NGC_API_KEY>
---
apiVersion: v1
kind: Secret
metadata:
  name: ngc-doca-oci-helm
  namespace: dpf-operator-system
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: nvstaging-doca-oci
  url: nvcr.io/nvidia/doca
  type: helm
  username: $oauthtoken
  password: <NGC_API_KEY>
```

Replace `<NGC_API_KEY>` with your NVIDIA NGC API key.

Apply the file:

```bash
$ oc apply -f ngc-secrets.yaml
```

# Expected output:
```
secret/ngc-doca-https-helm created
secret/ngc-doca-oci-helm created
```

Create the Helm values file for the DPF Operator:

```bash
$ cat > dpf-operator-values.yaml <<EOF
imagePullSecrets:
  - name: dpf-pull-secret
kamaji:
  enabled: false
kamaji-etcd:
  enabled: false
node-feature-discovery:
  enabled: false
enableNodeFeatureRules: false
isOpenshift: true
EOF
```

**Note**: NFD is disabled in the Helm chart because we install the Red Hat NFD Operator from OperatorHub separately. Kamaji is disabled because HyperShift is used for hosted cluster management. `enableNodeFeatureRules: false` prevents the DPF Operator from creating its own NodeFeatureRules (we use the NFD Operator's rules instead). `isOpenshift: true` enables OpenShift-specific configurations.

Install the DPF Operator:

```bash
$ helm install dpf-operator oci://ghcr.io/nvidia/dpf-operator \
    --version v26.4.0 \
    --namespace dpf-operator-system \
    --values dpf-operator-values.yaml
```

# Expected output:
```
NAME: dpf-operator
LAST DEPLOYED: ...
NAMESPACE: dpf-operator-system
STATUS: deployed
```

Verify the DPF Operator pods are running:

```bash
$ oc get pods -n dpf-operator-system -l app.kubernetes.io/name=dpf-operator
```

# Example output:
```
NAME                                          READY   STATUS    RESTARTS   AGE
dpf-operator-controller-manager-7b8f9c7-x2kp  1/1     Running   0          2m
```

Verify the DPF CRDs are installed:

```bash
$ oc get crd | grep dpu
```

# Example output:
```
bfbs.provisioning.dpu.nvidia.com                    2026-06-03T10:00:00Z
dpuclusters.provisioning.dpu.nvidia.com             2026-06-03T10:00:00Z
dpudeployments.svc.dpu.nvidia.com                   2026-06-03T10:00:00Z
dpuflavors.provisioning.dpu.nvidia.com              2026-06-03T10:00:00Z
dpuserviceconfigurations.svc.dpu.nvidia.com         2026-06-03T10:00:00Z
dpuservicecredentialrequests.svc.dpu.nvidia.com     2026-06-03T10:00:00Z
dpuserviceinterfaces.svc.dpu.nvidia.com             2026-06-03T10:00:00Z
dpuserviceipams.svc.dpu.nvidia.com                  2026-06-03T10:00:00Z
dpuservicetemplates.svc.dpu.nvidia.com              2026-06-03T10:00:00Z
dpusets.provisioning.dpu.nvidia.com                 2026-06-03T10:00:00Z
dpfoperatorconfigs.operator.dpu.nvidia.com          2026-06-03T10:00:00Z
```

## 5.4 Generate BF.cfg ConfigMap

**Note**: Manual BF.cfg ConfigMap generation is no longer required in DPF v26.4. The DPFOperatorConfig now includes `enableDynamicBFCFGTemplates: true` which handles BFB template generation automatically. See section 5.5.1 for the DPFOperatorConfig configuration.

## 5.5 Create DPF Resources

The DPFHCPProvisioner CR triggers the creation of the complete hosted cluster infrastructure, including the HostedCluster, MetalLB IPAddressPool, L2Advertisement, and kubeconfig injection into the DPUCluster.

Create the resource file:

```yaml
apiVersion: provisioning.dpu.hcp.io/v1alpha1
kind: DPFHCPProvisioner
metadata:
  name: $HOSTED_CLUSTER_NAME
  namespace: $CLUSTERS_NAMESPACE
spec:
  baseDomain: $BASE_DOMAIN
  dpuClusterRef:
    name: $HOSTED_CLUSTER_NAME
    namespace: dpf-operator-system
  dpuDeploymentRef:
    name: dpudeployment
    namespace: dpf-operator-system
  machineOSURL: $BLUEFIELD_OCP_IMAGE
  etcdStorageClass: $ETCD_STORAGE_CLASS
  ocpReleaseImage: $OCP_RELEASE_IMAGE
  pullSecretRef:
    name: $PULL_SECRET_NAME
  sshKeySecretRef:
    name: $SSH_KEY_SECRET_NAME
  controlPlaneAvailabilityPolicy: HighlyAvailable
  virtualIP: $HOSTED_CLUSTER_VIP
```

**Note**: The `controlPlaneAvailabilityPolicy` can be set to `SingleReplica` for single-node environments. When set to `HighlyAvailable`, the `virtualIP` field is required.

The following table describes each variable:

| Variable | Description | Example |
|----------|-------------|---------|
| `$HOSTED_CLUSTER_NAME` | Name for the hosted DPU cluster | `dpf-hosted` |
| `$CLUSTERS_NAMESPACE` | Namespace for hosted cluster resources | `clusters` |
| `$BASE_DOMAIN` | Base DNS domain | `example.com` |
| `$BLUEFIELD_OCP_IMAGE` | BlueField OCP image URL | `quay.io/eelgaev/bluefield-ocp:4.21.0_3.4.0-beta-v2` |
| `$ETCD_STORAGE_CLASS` | Storage class for etcd PVCs | `lvms-vg1` |
| `$OCP_RELEASE_IMAGE` | OCP release image for hosted cluster | `quay.io/openshift-release-dev/ocp-release:4.22.0-multi` |
| `$PULL_SECRET_NAME` | Name of the pull secret created above | `pull-secret` |
| `$SSH_KEY_SECRET_NAME` | Name of the SSH key secret created above | `ssh-key` |
| `$HOSTED_CLUSTER_VIP` | Virtual IP for the hosted cluster API | `192.168.1.200` |

Apply the file:

```bash
$ envsubst < dpfhcpprovisioner.yaml | oc apply -f -
```

# Expected output:
```
dpfhcpprovisioner.provisioning.dpu.hcp.io/dpf-hosted created
```

**Note**: The dpf-hcp-provisioner-operator automatically handles: HostedCluster creation, MetalLB IPAddressPool/L2Advertisement configuration, kubeconfig extraction and injection into DPUCluster, and DPU node CSR approval. These steps were previously performed manually.

## 6.6 Verify Hosted Cluster Creation

Monitor the hosted cluster creation and verify it becomes available.

Monitor the DPFHCPProvisioner status:

```bash
$ oc get dpfhcpprovisioner -n ${CLUSTERS_NAMESPACE}
```

# Example output:
```
NAME          AGE    STATUS
dpf-hosted    2m     Provisioning
```

Monitor the HostedCluster:

```bash
$ oc get hostedcluster -n ${CLUSTERS_NAMESPACE}
```

# Example output:
```
NAME          VERSION   KUBECONFIG                        PROGRESS    AVAILABLE
dpf-hosted              dpf-hosted-admin-kubeconfig       Partial     True
```

Wait for the hosted cluster to become available:

```bash
$ oc wait hostedcluster/${HOSTED_CLUSTER_NAME} -n ${CLUSTERS_NAMESPACE} \
    --for condition=Available --timeout=30m
```

# Expected output:
```
hostedcluster.hypershift.openshift.io/dpf-hosted condition met
```

Verify the kubeconfig secret was injected into the DPUCluster:

```bash
$ oc get secret ${HOSTED_CLUSTER_NAME}-admin-kubeconfig -n dpf-operator-system
```

# Example output:
```
NAME                              TYPE     DATA   AGE
dpf-hosted-admin-kubeconfig       Opaque   1      5m
```

Verify the hosted cluster control plane pods:

```bash
$ oc get pods -n clusters-${HOSTED_CLUSTER_NAME}
```

---

# Chapter 6: Hosted Cluster for DPU Control-Plane

This chapter covers the installation and configuration of the dpf-hcp-provisioner-operator, which automates the entire HyperShift hosted cluster lifecycle for DPU nodes. The dpf-hcp-provisioner-operator replaces the manual steps previously required for creating HostedClusters, extracting kubeconfigs, configuring MetalLB, and approving DPU CSRs.

What the operator automates:
- Creating a HostedCluster via HyperShift when a DPFHCPProvisioner CR is created
- Configuring MetalLB IPAddressPool and L2Advertisement for the hosted cluster VIP
- Extracting and injecting the hosted cluster kubeconfig into the DPUCluster resource
- Automatically approving CSRs for DPU nodes joining the hosted cluster

**Prerequisites**: The DPF Operator must be installed first (Chapter 5) because the dpf-hcp-provisioner-operator requires the DPF CRDs to be available.

**Note**: This section from the previous version has been replaced by the dpf-hcp-provisioner-operator workflow. In DPF v25.7.1, the hosted cluster was created explicitly using HyperShift Operator commands, MetalLB resources were configured manually, kubeconfigs were extracted by hand, and DPU CSRs required manual approval. In DPF v26.4, all of these steps are automated by the dpf-hcp-provisioner-operator.

## 6.1 Install dpf-hcp-provisioner-operator

The dpf-hcp-provisioner-operator is installed via Helm.

**Prerequisites**:
- MCE Operator installed and HyperShift enabled (section 4.3.6)
- MetalLB Operator installed with MetalLB instance created (section 4.3.4)
- Storage class available for etcd (ODF LVM or equivalent)
- DPF Operator installed and DPF CRDs available (Chapter 5)

Install the operator:

```bash
$ helm install dpf-hcp-provisioner-operator \
    oci://quay.io/lhadad/charts/dpf-hcp-provisioner-operator \
    --version 0.1.0 \
    --namespace dpf-hcp-provisioner-system \
    --create-namespace
```

# Expected output:
```
NAME: dpf-hcp-provisioner-operator
LAST DEPLOYED: ...
NAMESPACE: dpf-hcp-provisioner-system
STATUS: deployed
```

Verify the operator is running:

```bash
$ oc get pods -n dpf-hcp-provisioner-system
```

# Example output:
```
NAME                                                    READY   STATUS    RESTARTS   AGE
dpf-hcp-provisioner-controller-manager-xxx-yyy          1/1     Running   0          1m
```

## 6.2 Define Environment Variables

Set the following environment variables before creating the DPFHCPProvisioner resources. These variables are used throughout this chapter.

```bash
export HOSTED_CLUSTER_NAME="dpf-hosted"
export CLUSTERS_NAMESPACE="clusters"
export BASE_DOMAIN="example.com"
export BLUEFIELD_OCP_IMAGE="quay.io/eelgaev/bluefield-ocp:4.21.0_3.4.0-beta-v2"
export ETCD_STORAGE_CLASS="lvms-vg1"
export OCP_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.22.0-multi"
export HOSTED_CLUSTER_VIP="192.168.1.200"
export PULL_SECRET_NAME="pull-secret"
export SSH_KEY_SECRET_NAME="ssh-key"
```

## 6.3 Create DPFHCPProvisioner Secrets

Create the pull secret and SSH key secret required by the hosted cluster.

Create the namespace for hosted cluster resources:

```bash
$ oc create namespace ${CLUSTERS_NAMESPACE}
```

Create the pull secret for the hosted cluster:

```bash
$ oc create secret generic ${PULL_SECRET_NAME} \
    --from-file=.dockerconfigjson=$OPENSHIFT_PULL_SECRET \
    --type=kubernetes.io/dockerconfigjson \
    -n ${CLUSTERS_NAMESPACE}
```

# Expected output:
```
secret/pull-secret created
```

Create the SSH key secret:

```bash
$ oc create secret generic ${SSH_KEY_SECRET_NAME} \
    --from-file=id_rsa.pub=$SSH_KEY \
    -n ${CLUSTERS_NAMESPACE}
```

# Expected output:
```
secret/ssh-key created
```

## 6.4 Create DPUCluster Resource

The DPUCluster resource tells the DPF Operator about the hosted cluster where DPU services will run. The dpf-hcp-provisioner-operator will automatically inject the kubeconfig into this resource once the hosted cluster is created.

Create the resource file:

```yaml
apiVersion: provisioning.dpu.nvidia.com/v1alpha1
kind: DPUCluster
metadata:
  name: $HOSTED_CLUSTER_NAME
  namespace: dpf-operator-system
spec:
  type: static
  maxNodes: 10
  kubeconfig: ${HOSTED_CLUSTER_NAME}-admin-kubeconfig
```

**Note**: The `kubeconfig` field references a secret name that the dpf-hcp-provisioner-operator will create automatically. The `type: static` indicates this is a pre-provisioned cluster managed externally (by HyperShift).

Apply the file:

```bash
$ envsubst < dpucluster.yaml | oc apply -f -
```

# Expected output:
```
dpucluster.provisioning.dpu.nvidia.com/dpf-hosted created
```

## 6.5 Create DPFHCPProvisioner Resource

If using NFS storage for BFB images, create the PersistentVolume and PersistentVolumeClaim for BFB image storage.

Create the PersistentVolume:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: bfb-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteMany
  nfs:
    path: $NFS_BFB_PATH
    server: $NFS_SERVER_IP
  persistentVolumeReclaimPolicy: Retain
```

Create the PersistentVolumeClaim:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bfb-pvc
  namespace: dpf-operator-system
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
  volumeName: bfb-pv
```

Apply the files:

```bash
$ oc apply -f bfb-pv.yaml
$ oc apply -f bfb-pvc.yaml
```

# Expected output:
```
persistentvolume/bfb-pv created
persistentvolumeclaim/bfb-pvc created
```

## 6.3 Install DPF Operator

The DPF Operator is installed via Helm from the NVIDIA registry.

Create the pull secret for DPF images:

```yaml
apiVersion: v1
kind: Secret
metadata:
  labels:
    dpf.nvidia.com/image-pull-secret: ""
  name: dpf-pull-secret
  namespace: dpf-operator-system
data:
  .dockerconfigjson: <PULL_SECRET_BASE64>
type: kubernetes.io/dockerconfigjson
```

Replace `<PULL_SECRET_BASE64>` with your base64-encoded Docker config JSON containing credentials for `nvcr.io`, `ghcr.io`, and `quay.io`.

**Note**: To generate the base64-encoded value:
```bash
$ cat ~/.docker/config.json | base64 -w0
```

Apply the file:

```bash
$ oc apply -f dpf-pull-secret.yaml
```

# Expected output:
```
secret/dpf-pull-secret created
```

Create NGC Helm repository secrets for ArgoCD:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: ngc-doca-https-helm
  namespace: dpf-operator-system
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: nvstaging-doca-https
  url: https://helm.ngc.nvidia.com/nvidia/doca
  type: helm
  username: $oauthtoken
  password: <NGC_API_KEY>
---
apiVersion: v1
kind: Secret
metadata:
  name: ngc-doca-oci-helm
  namespace: dpf-operator-system
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: nvstaging-doca-oci
  url: nvcr.io/nvidia/doca
  type: helm
  username: $oauthtoken
  password: <NGC_API_KEY>
```

Replace `<NGC_API_KEY>` with your NVIDIA NGC API key.

Apply the file:

```bash
$ oc apply -f ngc-secrets.yaml
```

# Expected output:
```
secret/ngc-doca-https-helm created
secret/ngc-doca-oci-helm created
```

Create the Helm values file for the DPF Operator:

```bash
$ cat > dpf-operator-values.yaml <<EOF
imagePullSecrets:
  - name: dpf-pull-secret
kamaji:
  enabled: false
kamaji-etcd:
  enabled: false
node-feature-discovery:
  enabled: false
enableNodeFeatureRules: false
isOpenshift: true
EOF
```

**Note**: NFD is disabled in the Helm chart because we install the Red Hat NFD Operator from OperatorHub separately. Kamaji is disabled because HyperShift is used for hosted cluster management. `enableNodeFeatureRules: false` prevents the DPF Operator from creating its own NodeFeatureRules (we use the NFD Operator's rules instead). `isOpenshift: true` enables OpenShift-specific configurations.

Install the DPF Operator:

```bash
$ helm install dpf-operator oci://ghcr.io/nvidia/dpf-operator \
    --version v26.4.0 \
    --namespace dpf-operator-system \
    --values dpf-operator-values.yaml
```

# Expected output:
```
NAME: dpf-operator
LAST DEPLOYED: ...
NAMESPACE: dpf-operator-system
STATUS: deployed
```

Verify the DPF Operator pods are running:

```bash
$ oc get pods -n dpf-operator-system -l app.kubernetes.io/name=dpf-operator
```

# Example output:
```
NAME                                          READY   STATUS    RESTARTS   AGE
dpf-operator-controller-manager-7b8f9c7-x2kp  1/1     Running   0          2m
```

Verify the DPF CRDs are installed:

```bash
$ oc get crd | grep dpu
```

# Example output:
```
bfbs.provisioning.dpu.nvidia.com                    2026-06-03T10:00:00Z
dpuclusters.provisioning.dpu.nvidia.com             2026-06-03T10:00:00Z
dpudeployments.svc.dpu.nvidia.com                   2026-06-03T10:00:00Z
dpuflavors.provisioning.dpu.nvidia.com              2026-06-03T10:00:00Z
dpuserviceconfigurations.svc.dpu.nvidia.com         2026-06-03T10:00:00Z
dpuservicecredentialrequests.svc.dpu.nvidia.com     2026-06-03T10:00:00Z
dpuserviceinterfaces.svc.dpu.nvidia.com             2026-06-03T10:00:00Z
dpuserviceipams.svc.dpu.nvidia.com                  2026-06-03T10:00:00Z
dpuservicetemplates.svc.dpu.nvidia.com              2026-06-03T10:00:00Z
dpusets.provisioning.dpu.nvidia.com                 2026-06-03T10:00:00Z
dpfoperatorconfigs.operator.dpu.nvidia.com          2026-06-03T10:00:00Z
```

## 6.4 Generate BF.cfg ConfigMap

**Note**: Manual BF.cfg ConfigMap generation is no longer required in DPF v26.4. The DPFOperatorConfig now includes `enableDynamicBFCFGTemplates: true` which handles BFB template generation automatically. See section 6.5.1 for the DPFOperatorConfig configuration.

## 6.5 Create DPF Resources

### 6.5.1 DPFOperatorConfig 
Create DPFOperatorConfig resource file:
```yaml
apiVersion: operator.dpu.nvidia.com/v1alpha1
kind: DPFOperatorConfig
metadata:
  name: dpfoperatorconfig
  namespace: dpf-operator-system
spec:
  imagePullSecrets:
    - dpf-pull-secret
  kamajiClusterManager:
    disable: true
  multus:
    disable: true
  cniInstaller:
    disable: true
  networking:
    controlPlaneMTU: 9000
    highSpeedMTU: 9000
  overrides:
    dpuCNIBinPath: /var/lib/cni/bin/
    dpuCNIPath: /run/multus/cni/net.d/
    dpuOpenvSwitchSystemSharedLib64Path: /lib64
    flannelSkipCNIConfigInstallation: false
    kubernetesAPIServerPort: $TARGETCLUSTER_API_SERVER_PORT
    kubernetesAPIServerVIP: $HOST_CLUSTER_API
  provisioningController:
    enableDynamicBFCFGTemplates: true
    hostAgentDNSPolicy: Default
    bfbPVCName: bfb-pvc 
    dmsTimeout: 900
  nodeSRIOVDevicePluginController:
    devicePlugin:
      defaultResourcePrefix: openshift.io
    disable: false
    replicas: 1
  staticClusterManager:
    disable: false
```

Apply the resource file:
```bash
$ envsubst < dpfoperatorconfig.yaml | oc apply -f -
```

# Example output
```
dpfoperatorconfig.operator.dpu.nvidia.com/dpfoperatorconfig created
```

Follow the verification steps:
```bash
## Ensure the provisioning and DPUService controller manager deployments are available.
$ oc rollout status deployment --namespace dpf-operator-system dpf-provisioning-controller-manager
```
# Example output:
```
deployment "dpf-provisioning-controller-manager" successfully rolled out
```

```bash
$ oc rollout status deployment --namespace dpf-operator-system dpuservice-controller-manager
```
# Example output
```
deployment "dpuservice-controller-manager" successfully rolled out
```

## Ensure all pods in the DPF Operator system are Available
```bash
$ oc get pods -n dpf-operator-system
```

### 6.5.2 NodeSRIOVDevicePluginConfig

The NodeSRIOVDevicePluginConfig resource replaces the manual SR-IOV device plugin DaemonSet and control plane node patching from previous versions. It defines how SR-IOV VFs on the management cluster worker nodes are allocated to DPF components.

Create the resource file:

```yaml
apiVersion: noderesources.dpu.nvidia.com/v1alpha1
kind: NodeSRIOVDevicePluginConfig
metadata:
  name: bf3-p0-vfs
  namespace: dpf-operator-system
spec:
  devicePluginResources:
    - name: bf3-p0-vfs-mgmt
      type: vf
      ranges:
        - pfIndex: 0
          start: 1
          end: 1
    - name: bf3-p0-vfs
      type: vf
      options:
        isRdma: true
      ranges:
        - pfIndex: 0
          start: 2
          end: 45
```

Key configuration details:
- `bf3-p0-vfs-mgmt` -- Reserves VF index 1 on PF0 for DPU management connectivity
- `bf3-p0-vfs` -- Allocates VF indices 2-45 on PF0 for workload traffic with RDMA enabled
- The `pfIndex: 0` refers to the first physical function of the BlueField-3 DPU

Apply the file:

```bash
$ oc apply -f nodesriovdevicepluginconfig.yaml
```

# Expected output:
```
nodesriovdevicepluginconfig.noderesources.dpu.nvidia.com/bf3-p0-vfs created
```

Verify the config is applied:

```bash
$ oc get nodesriovdevicepluginconfig -n dpf-operator-system
```

# Example output:
```
NAME          AGE
bf3-p0-vfs    30s
```

### 6.5.3 DPUFlavor

The DPUFlavor defines the DPU configuration including NVConfig parameters, kernel arguments, hugepages, and the OVS initialization script. In DPF v26.4, the OVS `rawConfigScript` is specified in plaintext (not base64-encoded).

The `nvconfig` section contains BlueField-3 firmware parameters that the DPU agent applies via `mlxconfig` during provisioning. If any parameter differs from the current firmware configuration, the provisioning controller triggers a system-level reset so the changes take effect. The following parameters are required for DPF operation:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `INTERNAL_CPU_MODEL` | `1` | Switches the BlueField-3 to DPU mode (Arm cores active). A value of `0` keeps the card in NIC-only mode, which does not support DPF. |
| `SRIOV_EN` | `1` | Enables SR-IOV on both physical functions. The host agent creates Virtual Functions (VFs) that carry tenant traffic between the host and the DPU. |
| `NUM_OF_VFS` | `$NUM_VFS` | Number of VFs per physical function. Must match the value expected by the host agent (typically 46). |
| `LINK_TYPE_P1` / `LINK_TYPE_P2` | `ETH` | Sets both ports to Ethernet mode. DPF requires Ethernet; InfiniBand (`IB`) is not supported. |

**Note**: If the BlueField-3 is already configured with the correct values, the DPU agent reports `NoAction` and no reset occurs. You can verify the current firmware configuration before deployment by running `mlxconfig -d /dev/mst/mt41692_pciconf0 q` on the DPU worker node.

Create the resource file:

```yaml
apiVersion: provisioning.dpu.nvidia.com/v1alpha1
kind: DPUFlavor
metadata:
  name: hbn-ovnk
  namespace: dpf-operator-system
  annotations:
    provisioning.dpu.nvidia.com/skip-bfcfg-size-check: ""
spec:
  grub:
    kernelParameters:
      - console=hvc0
      - console=ttyAMA0
      - earlycon=pl011,0x13010000
      - iommu.passthrough=1
      - cgroup_no_v1=net_prio,net_cls
      - hugepagesz=2048kB
      - hugepages=250
  nvconfig:
    - device: '*'
      parameters:
        - PF_BAR2_ENABLE=0
        - PER_PF_NUM_SF=1
        - PF_TOTAL_SF=20
        - PF_SF_BAR_SIZE=10
        - NUM_PF_MSIX_VALID=0
        - PF_NUM_PF_MSIX_VALID=1
        - PF_NUM_PF_MSIX=228
        - INTERNAL_CPU_MODEL=1
        - INTERNAL_CPU_OFFLOAD_ENGINE=0
        - SRIOV_EN=1
        - NUM_OF_VFS=$NUM_VFS
        - LAG_RESOURCE_ALLOCATION=1
        - LINK_TYPE_P1=ETH
        - LINK_TYPE_P2=ETH
  ovs:
    rawConfigScript: |
      _ovs-vsctl() {
        ovs-vsctl --timeout 15 "$@"
      }
      _ovs-vsctl set Open_vSwitch . other_config:doca-init=true
      _ovs-vsctl set Open_vSwitch . other_config:dpdk-max-memzones=50000
      _ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
      _ovs-vsctl set Open_vSwitch . other_config:pmd-quiet-idle=true
      _ovs-vsctl set Open_vSwitch . other_config:max-idle=20000
      _ovs-vsctl set Open_vSwitch . other_config:max-revalidator=5000
      _ovs-vsctl set Open_vSwitch . other_config:doca-congestion-threshold=60
      _ovs-vsctl set Open_vSwitch . other_config:flow-limit=500000
      _ovs-vsctl set Open_vSwitch . other_config:hw-offload-ct-unidir-udp-enabled=true
      _ovs-vsctl remove Open_vSwitch . other_config default-datapath-type || true
      if systemctl list-unit-files openvswitch-switch.service &>/dev/null; then
        systemctl restart openvswitch-switch
      elif systemctl list-unit-files openvswitch.service &>/dev/null; then
        systemctl restart openvswitch
      fi
      _ovs-vsctl --may-exist add-br br-sfc
      _ovs-vsctl set bridge br-sfc datapath_type=netdev
      _ovs-vsctl set bridge br-sfc fail_mode=secure
      _ovs-vsctl --may-exist add-br br-hbn
      _ovs-vsctl set bridge br-hbn datapath_type=netdev
      _ovs-vsctl set bridge br-hbn fail_mode=secure
      _ovs-vsctl --may-exist add-port br-sfc p0
      _ovs-vsctl set Interface p0 type=dpdk
      _ovs-vsctl set Interface p0 mtu_request=9216
      _ovs-vsctl set Port p0 external_ids:dpf-type=physical
      # Activate DOCA for OVNK
      _ovs-vsctl set Open_vSwitch . external-ids:ovn-bridge-datapath-type=netdev
      # setup ovnkube managed bridge, br-dpu (this corresponds to br-ex on ovnk docs)
      _ovs-vsctl --may-exist add-br br-dpu
      _ovs-vsctl br-set-external-id br-dpu bridge-id br-dpu
      _ovs-vsctl br-set-external-id br-dpu bridge-uplink pbrdputobrovn
      _ovs-vsctl set bridge br-dpu datapath_type=netdev
      _ovs-vsctl --may-exist add-port br-dpu pf0hpf
      _ovs-vsctl set Interface pf0hpf type=dpdk
      # Create OVS bridge (br-ovn) in between the SC managed bridge and OVNK
      _ovs-vsctl --may-exist add-br br-ovn
      _ovs-vsctl set bridge br-ovn datapath_type=netdev
      _ovs-vsctl --may-exist add-port br-ovn pbrovntobrdpu
      _ovs-vsctl --may-exist add-port br-dpu pbrdputobrovn
      # Patch br-ovn and br-dpu together
      _ovs-vsctl set Interface pbrovntobrdpu type=patch options:peer=pbrdputobrovn
      _ovs-vsctl set Interface pbrdputobrovn type=patch options:peer=pbrovntobrdpu
```

Apply the resource file:
```bash
$ envsubst < dpuflavor.yaml | oc apply -f -  
```
              
# Example output               
```
dpuflavor.provisioning.dpu.nvidia.com/hbn-ovnk created
```

### 6.5.4 BFB

The BFB (BlueField Boot) image contains the RHCOS operating system and firmware for the DPU. The DPF Operator downloads the BFB image and stages it for DPU provisioning.

Create the resource file:

```yaml
apiVersion: provisioning.dpu.nvidia.com/v1alpha1
kind: BFB
metadata:
  name: bf-bundle
  namespace: dpf-operator-system
spec:
  url: $BFB_URL
```

Apply the resource file:
```bash
$ envsubst < bfb.yaml | oc apply -f -
```

# Expected output:
```
bfb.provisioning.dpu.nvidia.com/bf-bundle created
```

Verify the BFB image was downloaded successfully and Ready:
```bash
$ oc get bfbs.provisioning.dpu.nvidia.com -n dpf-operator-system bf-bundle -o yaml |grep phase
```

# Example output
```
phase: Ready
```

### 6.5.5 DPUDeployment

The DPUDeployment is the top-level resource that brings together DPUs, services, and service chains. It references the BFB image, DPUFlavor, and all service templates and configurations. Before creating the DPUDeployment, first create the NetworkPolicy for the DPF namespace.

Create the NetworkPolicy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: multi-port-egress
  namespace: dpf-operator-system
  annotations:
    k8s.ovn.org/acl-stateless: "true"
spec:
  podSelector: {}
  policyTypes:
    - Egress
    - Ingress
  egress:
    - {}
  ingress:
    - {}
```

Apply the file:

```bash
$ oc apply -f networkpolicy.yaml
```

# Expected output:
```
networkpolicy.networking.k8s.io/multi-port-egress created
```

Create the DPUDeployment resource file:

```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUDeployment
metadata:
  name: dpudeployment
  namespace: dpf-operator-system
spec:
  dpus:
    nodeEffect:
      drain: true
    dpuSetStrategy:
      type: RollingUpdate
    bfb: bf-bundle
    flavor: hbn-ovnk
    dpuSets:
      - nameSuffix: "dpuset1"
        dpuAnnotations:
          noderesources.dpu.nvidia.com/nodesriovdevicepluginconfig: bf3-p0-vfs
        nodeSelector:
          matchLabels:
            feature.node.kubernetes.io/dpu-enabled: ""
  services:
    hbn:
      serviceTemplate: hbn
      serviceConfiguration: hbn
    ovn:
      serviceTemplate: ovn
      serviceConfiguration: ovn
    doca-telemetry-service:
      serviceTemplate: doca-telemetry-service
      serviceConfiguration: doca-telemetry-service
  serviceChains:
    switches:
      - ports:
          - serviceInterface:
              matchLabels:
                uplink: p0
          - service:
              name: hbn
              interface: p0_if
      - ports:
          - serviceInterface:
              matchLabels:
                uplink: p1
          - service:
              name: hbn
              interface: p1_if
      - ports:
          - serviceInterface:
              matchLabels:
                port: ovn
          - service:
              name: hbn
              interface: pf2dpu2_if
```

Key configuration details:
- `nodeEffect.drain: true` -- Drains the worker node before provisioning the DPU
- `dpuSetStrategy.type: RollingUpdate` -- Updates DPUs one at a time
- `flavor: hbn-ovnk` -- References the DPUFlavor created in section 6.5.3
- `dpuAnnotations` -- Links the NodeSRIOVDevicePluginConfig to each DPU set
- `nodeSelector` -- Selects nodes labeled by NFD with `dpu-enabled: ""`
- Service chains connect physical uplinks (p0, p1) through HBN, and the OVN interface through the HBN `pf2dpu2_if` bridge port
- `doca-telemetry-service` -- Included as a new service in v26.4

Apply the file:

```bash
$ oc apply -f dpudeployment.yaml
```

# Expected output:
```
dpudeployment.svc.dpu.nvidia.com/dpudeployment created
```

Verify the DPUDeployment status:

```bash
$ oc get dpudeployment -n dpf-operator-system
```

# Example output:
```
NAME              AGE
dpudeployment     30s
```

## 6.6 Create DPU Services Resources

### 6.6.1 HBN DPU Service

Host-Based Networking (HBN) provides BGP routing capabilities on the DPU.

Create the HBN DPUServiceTemplate:

```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceTemplate
metadata:
  name: hbn
  namespace: dpf-operator-system
spec:
  deploymentServiceName: "hbn"
  helmChart:
    source:
      repoURL: $HBN_HELM_REPO_URL
      version: $HBN_HELM_CHART_VERSION
      chart: doca-hbn
    values:
      image:
        repository: $HBN_IMAGE_REPO
        tag: $HBN_IMAGE_TAG
      imagePullSecrets:
      - name: dpf-pull-secret
      resources:
        memory: 6Gi
        nvidia.com/bf_sf: 3
```

Apply the file:

```bash
$ oc apply -f hbn-template.yaml
```

# Expected output:
```
dpuservicetemplate.svc.dpu.nvidia.com/hbn created
```

Create the HBN DPUServiceConfiguration. The HBN configuration uses a Jinja2 template for startup configuration and includes per-DPU BGP autonomous system numbers.

**Important**: Update the `perDPUValuesYAML` section with hostname patterns and BGP AS numbers that match your environment. Each DPU host should have a unique BGP autonomous system number. The pattern uses glob matching against the DPU hostname. The HBN configuration uses dynamic AS number assignment: `{{ ( ipaddresses.ip_lo.ip.split(".")[3] | int ) + 65101 }}` can be used instead of static per-host patterns for automatic AS assignment based on loopback IP.

```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceConfiguration
metadata:
  name: hbn
  namespace: dpf-operator-system
spec:
  deploymentServiceName: "hbn"
  serviceConfiguration:
    serviceDaemonSet:
      annotations:
        k8s.v1.cni.cncf.io/networks: |-
          [
          {"name": "iprequest", "interface": "ip_lo", "cni-args": {"poolNames": ["loopback"], "poolType": "cidrpool"}},
          {"name": "iprequest", "interface": "ip_pf2dpu2", "cni-args": {"poolNames": ["pool1"], "poolType": "cidrpool", "allocateDefaultGateway": true}}
          ]
    helmChart:
      values:
        configuration:
          perDPUValuesYAML: |
            - hostnamePattern: "*"
              values:
                bgp_peer_group: hbn
          startupYAMLJ2: |
            - header:
                model: BLUEFIELD
                nvue-api-version: nvue_v1
                rev-id: 1.0
                version: HBN 2.4.0
            - set:
                interface:
                  lo:
                    ip:
                      address:
                        {{ ipaddresses.ip_lo.ip }}/32: {}
                    type: loopback
                  p0_if,p1_if:
                    type: swp
                    link:
                      mtu: 9216
                  pf2dpu2_if:
                    ip:
                      address:
                        {{ ipaddresses.ip_pf2dpu2.cidr }}: {}
                    type: swp
                    link:
                      mtu: 9216
                router:
                  bgp:
                    autonomous-system: {{ ( ipaddresses.ip_lo.ip.split(".")[3] | int ) + 65101 }}
                    enable: on
                    graceful-restart:
                      mode: full
                    router-id: {{ ipaddresses.ip_lo.ip }}
                vrf:
                  default:
                    router:
                      bgp:
                        address-family:
                          ipv4-unicast:
                            enable: on
                            redistribute:
                              connected:
                                enable: on
                          ipv6-unicast:
                            enable: on
                            redistribute:
                              connected:
                                enable: on
                        enable: on
                        neighbor:
                          p0_if:
                            peer-group: {{ config.bgp_peer_group }}
                            type: unnumbered
                          p1_if:
                            peer-group: {{ config.bgp_peer_group }}
                            type: unnumbered
                        path-selection:
                          multipath:
                            aspath-ignore: on
                        peer-group:
                          {{ config.bgp_peer_group }}:
                            remote-as: external
  interfaces:
    - name: p0_if
      network: mybrhbn
    - name: p1_if
      network: mybrhbn
    - name: pf2dpu2_if
      network: mybrhbn
```

Apply the file:

```bash
$ oc apply -f hbn-configuration.yaml
```

# Expected output:
```
dpuserviceconfiguration.svc.dpu.nvidia.com/hbn created
```

### 6.6.2 OVN-Kubernetes DPU Service

OVN-Kubernetes runs on each DPU to provide the accelerated data plane for pod networking.

Create the OVN DPUServiceTemplate:

```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceTemplate
metadata:
  name: ovn
  namespace: dpf-operator-system
spec:
  deploymentServiceName: "ovn"
  helmChart:
    source:
      repoURL: $OVN_TEMPLATE_CHART_URL
      chart: ovn-kubernetes-chart
      version: $OVN_CHART_VERSION
    values:
      commonManifests:
        enabled: true
      dpuManifests:
        image:
          repository: $OVN_KUBERNETES_IMAGE_REPO
          tag: $OVN_KUBERNETES_IMAGE_TAG
        enabled: true
        cniBinDir: /var/lib/cni/bin/
        cniConfDir: /run/multus/cni/net.d
      leaseNamespace: "openshift-ovn-kubernetes"
      gatewayOpts: "--gateway-interface=br-dpu"

Apply the file:

```bash
$ oc apply -f ovn-template.yaml
```

# Expected output:
```
dpuservicetemplate.svc.dpu.nvidia.com/ovn created
```

Create the OVN DPUServiceConfiguration:

```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceConfiguration
metadata:
  name: ovn
  namespace: dpf-operator-system
spec:
  deploymentServiceName: "ovn"
  serviceConfiguration:
    helmChart:
      values:
        global:
          enableOvnKubeIdentity: false
          imagePullSecretName: "dpf-pull-secret"
        k8sAPIServer: https://$HOST_CLUSTER_API:$TARGETCLUSTER_API_SERVER_PORT
        podNetwork: $POD_CIDR/23
        serviceNetwork: $SERVICE_CIDR
        mtu: 8940
        dpuManifests:
          ovnMultiNetworkEnable: "false"
          kubernetesSecretName: "ovn-dpu"
          vtepCIDR: $VTEP_CIDR
          hostCIDR: $TARGETCLUSTER_NODE_CIDR
          ipamPool: "pool1"
          ipamPoolType: "cidrpool"
          ipamVTEPIPIndex: 0
          ipamPFIPIndex: 1
          cniBinDir: "/var/lib/cni/bin/"
          cniConfDir: "/run/multus/cni/net.d"
```

Apply the resources file:
```bash
$ envsubst < ovn-configuration.yaml | oc apply -f -
```

# Example output
```
dpuserviceconfiguration.svc.dpu.nvidia.com/ovn created
```

### 6.6.3 OVN-Kubernetes DPUServiceCredentialRequest 
This resource enables the OVN-Kubernetes DPU service on the hosted cluster to authenticate with the management cluster's API server. The ClusterRoleBinding grants the required permissions for OVN node network operations.                                    

Create DPUServiceCredentialRequest resource file:
```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceCredentialRequest
metadata:
  name: ovn-dpu
  namespace: dpf-operator-system 
spec:
  serviceAccount:
    name: ovn-kubernetes-node-dpu-service
    namespace: openshift-ovn-kubernetes
  duration: 24h
  type: tokenFile
  secret:
    name: ovn-dpu
    namespace: dpf-operator-system
  metadata:
    labels:
      dpu.nvidia.com/image-pull-secret: ""
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ovn-kubernetes-node-limited-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openshift-ovn-kubernetes-node-limited
subjects:
- kind: ServiceAccount
  name: ovn-kubernetes-node-dpu-service
  namespace: openshift-ovn-kubernetes
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: openshift-ovn-kubernetes-node-limited-dpu-service
  namespace: openshift-ovn-kubernetes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: openshift-ovn-kubernetes-node-limited
subjects:
- kind: ServiceAccount
  name: ovn-kubernetes-node-dpu-service
  namespace: openshift-ovn-kubernetes
```

Apply the resource file:
```bash
$ oc apply -f ovn-credentials.yaml
```

# Expected output:
```
dpuservicecredentialrequest.svc.dpu.nvidia.com/ovn-dpu created
clusterrolebinding.rbac.authorization.k8s.io/ovn-kubernetes-node-limited-binding created
rolebinding.rbac.authorization.k8s.io/openshift-ovn-kubernetes-node-limited-dpu-service created
```

### 6.6.4 DPUServiceInterface Physical

DPUServiceInterface resources define the network interfaces available to DPU services. Create the physical uplink interfaces for p0 and p1.

Create the resource file:

```yaml
---
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceInterface
metadata:
  name: p0
  namespace: dpf-operator-system
spec:
  template:
    spec:
      template:
        metadata:
          labels:
            uplink: "p0"
        spec:
          interfaceType: physical
          physical:
            interfaceName: p0
---
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceInterface
metadata:
  name: p1
  namespace: dpf-operator-system
spec:
  template:
    spec:
      template:
        metadata:
          labels:
            uplink: "p1"
        spec:
          interfaceType: physical
          physical:
            interfaceName: p1
```

Apply the file:

```bash
$ oc apply -f physical-ifaces.yaml
```

# Expected output:
```
dpuserviceinterface.svc.dpu.nvidia.com/p0 created
dpuserviceinterface.svc.dpu.nvidia.com/p1 created
```

**Note**: HBN service interfaces (p0_if, p1_if, pf2dpu2_if) are defined in the HBN DPUServiceConfiguration interfaces section and do not require separate DPUServiceInterface resources.

### 6.6.5 DPUServiceInterface OVN-Kubernetes

Create the OVN service interface:

```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceInterface
metadata:
  name: ovn
  namespace: dpf-operator-system
spec:
  template:
    spec:
      template:
        metadata:
          labels:
            port: ovn
        spec:
          interfaceType: ovn
```

Apply the file:

```bash
$ oc apply -f ovn-iface.yaml
```

# Expected output:
```
dpuserviceinterface.svc.dpu.nvidia.com/ovn created
```

### 6.6.6 DPUServiceNADs

**Note**: This section from the previous version has been removed. DPUServiceNAD resources are no longer required in DPF v26.4. Network attachment definitions for DPU services are now managed automatically by the DPF Operator.

### 6.6.7 DPUServiceIPAM

IPAM resources define the IP address pools used by DPU services for VTEP and loopback addresses.

Create the VTEP network IPAM pool (used by HBN and OVN for inter-DPU communication):

```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceIPAM
metadata:
  name: pool1
  namespace: dpf-operator-system
spec:
  ipv4Network:
    network: $VTEP_CIDR
    gatewayIndex: 3
    prefixSize: 29
```

Apply the resource file:
```bash
$ envsubst < dpuservice-ipam.yaml | oc apply -f -
```

# Expected output:
```
dpuserviceipam.svc.dpu.nvidia.com/pool1 created
```

Create the loopback IPAM pool (used for BGP router IDs):

```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceIPAM
metadata:
  name: loopback
  namespace: dpf-operator-system
spec:
  ipv4Network:
    network: "11.0.0.0/24"
    prefixSize: 32
```

Apply the file:

```bash
$ oc apply -f hbn-loopback-ipam.yaml
```

# Expected output:
```
dpuserviceipam.svc.dpu.nvidia.com/loopback created
```

### 6.6.8 DOCA Telemetry Service

DOCA Telemetry Service (DTS) provides monitoring and metrics collection from the DPU hardware.

Create DTS DPU Service resources file:
```yaml
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceTemplate
metadata:
  name: doca-telemetry-service
  namespace: dpf-operator-system
spec:
  deploymentServiceName: "doca-telemetry-service"
  resourceRequirements:
    cpu: 1
    memory: 1Gi
    storage: 1Gi
  helmChart:
    source:
      repoURL: $DTS_HELM_REPO_URL
      chart: doca-telemetry
      version: $DTS_HELM_CHART_VERSION
    values:
      configMapData:
        prometheus:
          port: 9189
      hostVolumePrefix: "/var/lib"
      imageDTS: $DTS_IMAGE
      imagePullSecrets:
        - name: dpf-pull-secret
---
apiVersion: svc.dpu.nvidia.com/v1alpha1
kind: DPUServiceConfiguration
metadata:
  name: doca-telemetry-service
  namespace: dpf-operator-system
spec:
  deploymentServiceName: "doca-telemetry-service"
  serviceConfiguration: {}
```

Apply the resources file:
```bash
$ envsubst < dts.yaml | oc apply -f -
```

# Example output
```
dpuservicetemplate.svc.dpu.nvidia.com/doca-telemetry-service created
dpuserviceconfiguration.svc.dpu.nvidia.com/doca-telemetry-service created
```

## 6.7 Verify DPU Services Resources

Verify all DPU service resources have been created successfully.

```bash
$ oc get dpuservicetemplates -n dpf-operator-system
```

# Example output:
```
NAME                     AGE
hbn                      5m
ovn                      4m
doca-telemetry-service   3m
```

```bash
$ oc get dpuserviceconfigurations -n dpf-operator-system
```

# Example output:
```
NAME                     AGE
hbn                      5m
ovn                      4m
doca-telemetry-service   3m
```

```bash
$ oc get dpuserviceinterfaces -n dpf-operator-system
```

# Example output:
```
NAME      AGE
p0        5m
p1        5m
app-sf    4m
p0-sf     4m
p1-sf     4m
ovn       3m
```

```bash
$ oc get dpuserviceipams -n dpf-operator-system
```

# Example output:
```
NAME       AGE
pool1      5m
loopback   4m
```

---

# Chapter 7: OVN-Kubernetes CNI Adjustments

This chapter covers the deployment of the OVN-Kubernetes Resource Injector on the management cluster and the configuration of the Cluster Network Operator for DPU-host mode.

## 7.1 Enable OVN-Kubernetes Resource Injector

The OVN-Kubernetes Resource Injector is a mutating webhook that automatically injects network-attachment-definition references into pod specs on the management cluster. This enables pods on DPU-attached worker nodes to use the OVN network provided by the DPU.

Create the `ovn-kubernetes` namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ovn-kubernetes
  labels:
    openshift.io/run-level: "0"
    openshift.io/cluster-monitoring: "true"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
  annotations:
    openshift.io/node-selector: ""
    openshift.io/description: "OVN Kubernetes components"
    workload.openshift.io/allowed: "management"
```

Apply the file:

```bash
$ oc apply -f ovn-kubernetes-ns.yaml
```

# Expected output:
```
namespace/ovn-kubernetes created
```

Apply the OVN-Kubernetes Resource Injector manifests. The injector manifests are generated from the OVN chart version v26.4.0-ocpbeta:

```bash
$ oc apply -f ovn-injector.yaml
```

# Expected output:
```
namespace/ovn-host-network created
serviceaccount/release-name-ovn-kubernetes-resource-injector created
clusterrole.rbac.authorization.k8s.io/release-name-ovn-kubernetes-resource-injector-role created
clusterrolebinding.rbac.authorization.k8s.io/release-name-ovn-kubernetes-resource-injector-rolebinding created
role.rbac.authorization.k8s.io/release-name-ovn-kubernetes-resource-injector-leader-election-role created
rolebinding.rbac.authorization.k8s.io/release-name-ovn-kubernetes-resource-injector-leader-election-rolebinding created
service/release-name-ovn-kubernetes-resource-injector-webhook created
deployment.apps/release-name-ovn-kubernetes-resource-injector created
certificate.cert-manager.io/release-name-ovn-kubernetes-resource-injector-webhook created
issuer.cert-manager.io/release-name-ovn-kubernetes-resource-injector created
mutatingwebhookconfiguration.admissionregistration.k8s.io/release-name-ovn-kubernetes-resource-injector created
```

**Note**: The injector deployment runs on control plane nodes (via `nodeSelector: node-role.kubernetes.io/control-plane: ""`). It requires cert-manager to be installed and running for TLS certificate provisioning.

Verify the injector is running:

```bash
$ oc get pods -n ovn-kubernetes -l app.kubernetes.io/name=ovn-kubernetes-resource-injector
```

# Example output:
```
NAME                                                          READY   STATUS    RESTARTS   AGE
release-name-ovn-kubernetes-resource-injector-xxx-yyy         1/1     Running   0          2m
```

Verify the webhook is configured:

```bash
$ oc get mutatingwebhookconfiguration release-name-ovn-kubernetes-resource-injector
```

# Example output:
```
NAME                                                 WEBHOOKS   AGE
release-name-ovn-kubernetes-resource-injector         1          2m
```

## 7.2 Enable OVN-Kubernetes DPU-Host Mode

Configure the Cluster Network Operator (CNO) to recognize DPU-equipped nodes and use the appropriate management VF resource.

Create the hardware offload ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hardware-offload-config
  namespace: openshift-network-operator
data:
  dpu-host-mode-label: "feature.node.kubernetes.io/dpu-enabled="
  mgmt-port-resource-name: "openshift.io/bf3-p0-vfs-mgmt"
```

Key configuration:
- `dpu-host-mode-label` -- Matches the NFD label applied to DPU-equipped worker nodes
- `mgmt-port-resource-name` -- References the management VF resource from the NodeSRIOVDevicePluginConfig (`bf3-p0-vfs-mgmt`)

Apply the file:

```bash
$ oc apply -f cno-dpu-host-cm.yaml
```

# Expected output:
```
configmap/hardware-offload-config created
```

Verify the CNO picks up the configuration:

```bash
$ oc get configmap hardware-offload-config -n openshift-network-operator -o yaml
```

**Note**: After applying this ConfigMap, the CNO will configure OVN-Kubernetes to use the specified management VF for the OVN management port on DPU-host nodes, instead of a regular veth interface.

---

# Chapter 8: Adding Worker Nodes

This chapter covers adding DPU-equipped worker nodes to the management cluster, approving CSRs, monitoring DPU provisioning, and configuring authorization on the hosted cluster.

## 8.1 Prerequisites

Before adding worker nodes, ensure the following are complete:
- All MachineConfig resources from section 4.1 have been applied and rolled out
- All operators from section 4.3 are installed and running
- The DPF Operator is installed and DPFOperatorConfig shows Ready (section 5.5.1)
- All DPU service resources from section 5.6 have been created
- The dpf-hcp-provisioner-operator has created the hosted cluster (section 6.6)
- The OVN-Kubernetes Resource Injector and DPU-host mode ConfigMap are applied (Chapter 7)

## 8.2 Add Worker Nodes

### 8.2.1 Option 1: Adding Worker Nodes Using Assisted Installer

If using the Red Hat Assisted Installer, add worker nodes through the Assisted Installer UI or API. The workers will automatically boot with the RHCOS image and join the management cluster.

### 8.2.2 Option 2: Adding Worker Nodes Using Baremetal Operator

For bare-metal deployments, create BareMetalHost resources or use MachineSet scaling:

```bash
$ oc scale machineset <MACHINESET_NAME> -n openshift-machine-api --replicas=<DESIRED_COUNT>
```

Monitor the nodes joining the cluster:

```bash
$ oc get nodes -w
```

# Example output:
```
NAME          STATUS     ROLES           AGE   VERSION
master-0      Ready      control-plane   1d    v1.35.0
master-1      Ready      control-plane   1d    v1.35.0
master-2      Ready      control-plane   1d    v1.35.0
worker-0      NotReady   worker          10s   v1.35.0
```

## 8.3 Approve Worker Nodes Certificate Requests

Worker node CSRs on the management cluster must be approved manually. DPU node CSRs on the hosted cluster are approved automatically by the dpf-hcp-provisioner-operator.

List pending CSRs:

```bash
$ oc get csr | grep Pending
```

# Example output:
```
csr-abc123   5m    kubernetes.io/kube-apiserver-client-kubelet   Pending
csr-def456   5m    kubernetes.io/kubelet-serving                 Pending
```

Approve all pending CSRs:

```bash
$ oc get csr -o name | xargs oc adm certificate approve
```

# Expected output:
```
certificatesigningrequest.certificates.k8s.io/csr-abc123 approved
certificatesigningrequest.certificates.k8s.io/csr-def456 approved
```

**Note**: You may need to run this command multiple times as new CSRs appear during node bootstrap.

Verify worker nodes are Ready:

```bash
$ oc get nodes -l node-role.kubernetes.io/worker
```

# Example output:
```
NAME          STATUS   ROLES    AGE   VERSION
worker-0      Ready    worker   5m    v1.35.0
worker-1      Ready    worker   5m    v1.35.0
```

## 8.4 Verify DPU Provisioning

Once worker nodes are ready and the DPUDeployment is applied, the DPF Operator begins provisioning the DPUs.

Check that NFD has labeled the worker nodes:

```bash
$ oc get nodes -l feature.node.kubernetes.io/dpu-enabled
```

# Example output:
```
NAME          STATUS   ROLES    AGE   VERSION
worker-0      Ready    worker   10m   v1.35.0
```

Monitor DPU provisioning:

```bash
$ oc get dpusets -n dpf-operator-system
```

# Example output:
```
NAME                    READY   AGE
dpudeployment-dpuset1   0/1     2m
```

Check individual DPU status:

```bash
$ oc get dpus -n dpf-operator-system
```

# Example output:
```
NAME                     PHASE          AGE
worker-0-bf3-0           Provisioning   5m
```

Wait for DPU provisioning to complete:

```bash
$ oc get dpus -n dpf-operator-system -w
```

# Expected output:
```
NAME                     PHASE     AGE
worker-0-bf3-0           Ready     15m
```

**Note**: DPU provisioning involves firmware updates, BFB installation, and service deployment. This process typically takes 15-30 minutes per DPU.

Verify DPU nodes joined the hosted cluster:

```bash
$ oc get secret ${HOSTED_CLUSTER_NAME}-admin-kubeconfig -n dpf-operator-system \
    -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/hosted-kubeconfig

$ KUBECONFIG=/tmp/hosted-kubeconfig oc get nodes
```

# Example output:
```
NAME                     STATUS   ROLES    AGE   VERSION
worker-0-bf3-0           Ready    worker   5m    v1.35.0
```

Verify DPU services are running on the hosted cluster:

```bash
$ KUBECONFIG=/tmp/hosted-kubeconfig oc get pods -n dpf-operator-system
```

# Example output:
```
NAME                              READY   STATUS    RESTARTS   AGE
doca-hbn-xxxxx                    1/1     Running   0          5m
ovn-kubernetes-node-xxxxx         3/3     Running   0          5m
doca-telemetry-service-xxxxx      1/1     Running   0          5m
```

## 8.5 Authorization Configuration for the Hosted DPU Cluster Components

Create the required Security Context Constraint (SCC) bindings on the hosted cluster so that DPU services can run with privileged access. These must be applied using the hosted cluster kubeconfig.

```bash
$ KUBECONFIG=/tmp/hosted-kubeconfig oc apply -f dpu-services-scc.yaml
```

The SCC ClusterRoleBindings resource file:

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: doca-hbn-scc-rolebinding
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/part-of: dpu-services
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: default
    namespace: dpf-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ovn-dpu-scc-rolebinding
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/part-of: dpu-services
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: ovn-dpu
    namespace: dpf-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ovn-kubernetes-node-scc-rolebinding
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/part-of: dpu-services
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: Group
    name: system:serviceaccounts:dpf-operator-system
    apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sriov-device-plugin-scc-rolebinding
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/part-of: dpu-services
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: sriov-device-plugin
    namespace: dpf-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nvidia-k8s-ipam-scc-rolebinding
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/part-of: dpu-services
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: cluster-nvidia-k8s-ipam-node
    namespace: dpf-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ovs-cni-scc-rolebinding
  labels:
    app.kubernetes.io/component: rbac
    app.kubernetes.io/part-of: dpu-services
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: cluster-ovs-cni-marker
    namespace: dpf-operator-system
```

# Expected output:
```
clusterrolebinding.rbac.authorization.k8s.io/doca-hbn-scc-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/ovn-dpu-scc-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/ovn-kubernetes-node-scc-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/sriov-device-plugin-scc-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/nvidia-k8s-ipam-scc-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/ovs-cni-scc-rolebinding created
```

## 8.6 DPU CSR Approval

The dpf-hcp-provisioner-operator automatically approves CSRs for DPU nodes joining the hosted cluster. No manual CSR approval is required for DPU nodes.

If automatic CSR approval is not functioning, the following manual commands can be used as a fallback:

```bash
$ KUBECONFIG=/tmp/hosted-kubeconfig oc get csr | grep Pending
$ KUBECONFIG=/tmp/hosted-kubeconfig oc get csr -o name | xargs oc adm certificate approve
```

To verify DPU CSR approval is working:

```bash
$ oc logs -n dpf-hcp-provisioner-system deployment/dpf-hcp-provisioner-controller-manager | grep -i csr
```

## 8.7 Verify Cluster Readiness

Perform final verification that the complete deployment is operational.

Verify all DPU resources:

```bash
$ oc get dpudeployment,dpusets,dpus,bfbs,dpuflavors -n dpf-operator-system
```

Verify all DPU services:

```bash
$ oc get dpuservicetemplates,dpuserviceconfigurations,dpuserviceinterfaces,dpuserviceipams -n dpf-operator-system
```

Verify the hosted cluster is healthy:

```bash
$ KUBECONFIG=/tmp/hosted-kubeconfig oc get nodes
$ KUBECONFIG=/tmp/hosted-kubeconfig oc get pods -n dpf-operator-system
```

Return to the management cluster context:

```bash
$ unset KUBECONFIG
```

---

# Chapter 9: Traffic Validation Test

After DPU provisioning is complete and all services are running, validate end-to-end traffic flow through the DPU-accelerated data path.

## 9.1 Create Traffic Test Pods/Services

Create test pods on DPU-equipped worker nodes to validate OVN-Kubernetes connectivity.

Create a test pod on a DPU-equipped worker:

```bash
$ cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-1
  namespace: default
spec:
  nodeSelector:
    feature.node.kubernetes.io/dpu-enabled: ""
  containers:
    - name: test
      image: registry.access.redhat.com/ubi9/ubi:latest
      command: ["sleep", "infinity"]
EOF
```

# Expected output:
```
pod/test-pod-1 created
```

Verify the pod is running and has an IP:

```bash
$ oc get pod test-pod-1 -o wide
```

# Example output:
```
NAME         READY   STATUS    RESTARTS   AGE   IP             NODE
test-pod-1   1/1     Running   0          30s   10.128.2.15    worker-0
```

Create a second test pod (optionally on a different worker node):

```bash
$ cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-2
  namespace: default
spec:
  nodeSelector:
    feature.node.kubernetes.io/dpu-enabled: ""
  containers:
    - name: test
      image: registry.access.redhat.com/ubi9/ubi:latest
      command: ["sleep", "infinity"]
EOF
```

## 9.2 Run Traffic Validation Tests

Test connectivity from the first pod to the Kubernetes API server:

```bash
$ oc exec test-pod-1 -- curl -s -o /dev/null -w "%{http_code}" https://kubernetes.default.svc:443 -k
```

# Expected output:
```
403
```

A `403` response confirms connectivity to the Kubernetes API server through the DPU-accelerated data path.

Test connectivity between pods:

```bash
$ POD2_IP=$(oc get pod test-pod-2 -o jsonpath='{.status.podIP}')
$ oc exec test-pod-1 -- ping -c 3 ${POD2_IP}
```

# Example output:
```
PING 10.128.3.10 (10.128.3.10) 56(84) bytes of data.
64 bytes from 10.128.3.10: icmp_seq=1 ttl=62 time=0.234 ms
64 bytes from 10.128.3.10: icmp_seq=2 ttl=62 time=0.198 ms
64 bytes from 10.128.3.10: icmp_seq=3 ttl=62 time=0.201 ms
```

Verify HBN BGP peering on the hosted cluster:

```bash
$ KUBECONFIG=/tmp/hosted-kubeconfig oc exec -it \
    $(oc get pods -n dpf-operator-system -l app=doca-hbn -o name | head -1) \
    -n dpf-operator-system -- nv show router bgp neighbor
```

Verify OVS bridges on the DPU:

```bash
$ KUBECONFIG=/tmp/hosted-kubeconfig oc debug node/<DPU_NODE_NAME>
sh-5.1# chroot /host
sh-5.1# ovs-vsctl show
```

The following bridges should exist:
- `br-sfc` -- Service function chaining bridge
- `br-hbn` -- HBN bridge
- `br-dpu` -- OVN-Kubernetes bridge (corresponds to br-ex)
- `br-ovn` -- Bridge connecting service chain to OVN-K

Clean up test pods:

```bash
$ oc delete pod test-pod-1 test-pod-2 -n default
```

---

# Chapter 10: DPU Telemetry (DTS) Observability on OpenShift

This chapter shows how to deploy the DOCA Telemetry Service (DTS) on a DPF/OCP cluster and view DPU hardware telemetry (PCIe link, uplink throughput, packets, errors, NIC channels) — first using the native OpenShift console, then optionally using Grafana.

DTS runs on every DPU and exposes DPU counters (sysfs/ethtool) on a Prometheus metrics endpoint. Those metrics are scraped by OpenShift's built-in user-workload monitoring — so on OCP you do not need to install a separate Prometheus.

**Important**: Neither the DPF operator nor the DTS DPUService installs Grafana on OpenShift. In a standard openshift-dpf automated deployment, Grafana and all dashboards are deployed by the post-install observability step (`scripts/post-install.sh observability`). That step installs the grafana-operator, creates a Grafana instance with a Prometheus datasource, deploys DPF framework dashboards, and sets up DPF controller and kube-state-metrics scraping. The manual steps below walk through each piece individually — follow them if you are adding observability to an existing cluster or want to understand the components.

## 10.1 How DPF Exposes DTS Metrics to the Management Cluster

DTS runs on the DPU (hosted) cluster, but Prometheus runs on the management cluster. DPF bridges this with a built-in mechanism: a DPUService's `configPorts` makes DPF publish the service port as a NodePort on the DPU cluster and mirror it as a Service on the management cluster (labeled `dpu.nvidia.com/exposed-port-for-dpucluster`). The management-cluster Prometheus then scrapes that mirror Service. Nothing extra is required — this is how DTS metrics become reachable.

### 10.1.1 Prerequisites

- A deployed DPF/OCP cluster with at least one provisioned DPU.
- `oc` logged in to the management cluster as cluster-admin.
- Run commands from the root of the openshift-dpf repo (paths below are relative to it).

### 10.1.2 Step 1 — Enable OpenShift User-Workload Monitoring

OpenShift ships with Prometheus, but by default it only monitors OpenShift's own components. To allow it to scrape user namespaces (where DPF and DTS live, e.g. `dpf-operator-system`), enable user-workload monitoring (UWM). This is done by setting `enableUserWorkload: true` in the `cluster-monitoring-config` ConfigMap in the `openshift-monitoring` namespace.

Apply the manifest from this repo:

```bash
$ oc apply -f manifests/cluster-installation/cluster-monitoring-config.yaml
```

It contains:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

If the ConfigMap already exists with other settings, don't overwrite it — edit it instead and add the one line:

```bash
$ oc -n openshift-monitoring edit configmap cluster-monitoring-config
```

Enabling UWM makes OpenShift spin up a dedicated monitoring stack in the `openshift-user-workload-monitoring` namespace. Verify the pods are running:

```bash
$ oc -n openshift-user-workload-monitoring get pods
# Expect: prometheus-user-workload-*, thanos-ruler-user-workload-*,
#         prometheus-operator-*  (all Running)
```

### 10.1.3 Step 2 — Deploy the DTS DPUService

DTS is deployed like any other DPU service in DPF, via three objects:

- **dts-template.yaml** (DPUServiceTemplate) — the Helm chart (`doca-telemetry`), the DTS image, and the metrics port (`configMapData.prometheus.port: 9189`).
- **dts-configuration.yaml** (DPUServiceConfiguration) — declares the service port `httpserverport: 9189` under `configPorts` (this is what triggers the management-cluster port exposure described above).
- **dpudeployment.yaml** (DPUDeployment) — references the template + configuration so DTS is rolled out to the DPUs (as a DaemonSet on the DPU cluster). DTS defaults to the `sysfs` and `ethtool` providers.

Apply them:

```bash
$ oc apply -f manifests/post-installation/dts-template.yaml
$ oc apply -f manifests/post-installation/dts-configuration.yaml
# dpudeployment.yaml lists doca-telemetry-service under spec.services
$ oc apply -f manifests/post-installation/dpudeployment.yaml
```

In a standard openshift-dpf install these are applied automatically by the post-install step. Apply them manually only when adding DTS to an existing cluster.

### 10.1.4 Step 3 — Tell Prometheus to Scrape DTS

A ServiceMonitor points UWM Prometheus at the DTS metrics endpoint. Apply it:

```bash
$ oc apply -f manifests/post-installation/dts-servicemonitor.yaml
```

This ServiceMonitor (in `dpf-operator-system`) selects the mirrored DTS Service and scrapes its `/metrics` on the `httpserverport` every 30s.

### 10.1.5 Step 4 — Apply the DTS Console Dashboard

The native OpenShift console can display dashboards under **Observe → Dashboards** without Grafana. This works by creating a ConfigMap in the `openshift-config-managed` namespace with the label `console.openshift.io/dashboard: "true"` — the console monitoring plugin discovers it automatically and adds it to the dashboard dropdown.

Apply the DTS console dashboard:

```bash
$ oc apply -f manifests/observability/console-dashboards/dts-console-dashboard.yaml
```

In a standard openshift-dpf automated deployment, this is applied by the post-install observability step. Apply it manually only when adding DTS dashboards to an existing cluster.

**Note**: This dashboard renders against the platform Thanos/UWM Prometheus — no Grafana dependency.

### 10.1.6 Step 5 — Verify the DTS DPUService Is Up

Confirm the DTS DPUService is Ready on the management cluster. The object name carries a generated suffix (e.g. `doca-telemetry-service-89p28`), so select it by its stable label instead:

```bash
$ oc -n dpf-operator-system get dpuservice \
  -l svc.dpu.nvidia.com/dpudeployment-service=doca-telemetry-service
# NAME                           READY   PHASE     AGE
# doca-telemetry-service-89p28   True    Success   ...
```

`READY: True` / `PHASE: Success` means DTS is deployed and running.

#### a. View in the Native OpenShift Console

No Grafana required — the OpenShift console reads the cluster's own Prometheus.

**Dashboard view.** Console → **Observe** → **Dashboards** → in the Dashboard dropdown select **"DOCA DPU Telemetry (DTS)"**. It shows PCIe link speed/width, uplink throughput, packets/s, errors & drops/s, and NIC channel activity, with each DPU as its own line.

**Ad-hoc queries.** Console → **Observe** → **Metrics**, then enter a DTS query and click **Run queries**:

```
current_link_speed{job=~"doca-telemetry-service.*"}
```

You should get one series per DPU. Hover a line to see its labels — note `source`, which is the DPU node name (how you tell DPUs apart). Other useful queries:

```
rate(p0_eth_rx_bytes{job=~"doca-telemetry-service.*"}[5m]) * 8   # uplink RX bits/s
rate(ch_poll{job=~"doca-telemetry-service.*"}[5m])               # NIC channel activity
```

#### b. View in Grafana (Optional)

Grafana provides richer dashboards with per-DPU dropdown filters and customizable panels. It is **not** installed by default on OpenShift — neither the DPF operator nor DTS deploy it. In a standard openshift-dpf automated deployment, Grafana and all dashboards are installed by the post-install observability step:

```bash
$ scripts/post-install.sh observability
```

That single command installs the grafana-operator, creates the Grafana instance with a Prometheus datasource, deploys RBAC for Prometheus access, applies all DPF framework dashboards (see section c below), sets up kube-state-metrics, and configures DPF controller scraping.

To install manually instead, follow the steps below.

**Step 1 — Install the Grafana operator:**

```bash
$ oc apply -f manifests/observability/operators/grafana-operator-subscription.yaml
```

Wait for the operator to install (this can take several minutes for the bundle to unpack):

```bash
$ oc get csv -n openshift-operators | grep grafana
# grafana-operator.v5.x.x   Grafana Operator   5.x.x   grafana-operator   Succeeded
```

**Step 2 — Deploy DPF metrics scraping (kube-state-metrics and DPF controller):**

```bash
$ oc apply -f manifests/observability/dpf-metrics/
```

This deploys a kube-state-metrics instance scoped to DPF CRDs, a PodMonitor for the DPF controller, and the necessary RBAC. These feed the DPF framework dashboards.

**Step 3 — Deploy the Grafana instance, datasource, RBAC, and dashboards:**

```bash
$ oc apply -f manifests/observability/grafana/grafana-rbac.yaml
$ oc apply -f manifests/observability/grafana/grafana-cr.yaml
$ oc apply -f manifests/observability/grafana/grafana-datasource.yaml
$ oc apply -f manifests/observability/grafana/grafana-dashboards.yaml
```

The `grafana-dashboards.yaml` creates GrafanaDashboard CRs that reference the dashboard ConfigMaps the DPF operator already created. Grafana loads them automatically.

To also load the DTS-specific Grafana dashboard (if available in your repo version):

```bash
$ oc apply -f manifests/observability/grafana/dts-grafana-dashboard.yaml
```

**Step 4 — Access Grafana:**

```bash
$ echo "https://$(oc -n dpf-operator-system get route dpf-grafana-route -o jsonpath='{.spec.host}')"
```

Open it in a browser. Anonymous access is read-only Viewer; to edit, click **Sign in** and use `admin` / `admin` (the default set in the Grafana CR — change it for non-lab clusters).

Go to **Dashboards** → open **"DOCA DPU Telemetry (DTS)"**. Use the **DPU (source)** dropdown at the top to focus on one DPU or select All. Adjust the time range (top-right); it refreshes every 30s.

**Note**: If the grafana-operator bundle fails to unpack (`DeadlineExceeded`), this typically indicates slow connectivity to the community-operators registry. The native console dashboard (Step 4 above) provides equivalent functionality without Grafana.

#### c. DPF Framework Dashboards

Separately from DTS, the DPF operator ships framework dashboards that track DPU lifecycle and control-plane health (not DPU hardware telemetry). The DPF operator creates the dashboard data as ConfigMaps (`dpf-operator-grafana-dashboards` and `dpf-operator-grafana-debug-dashboards`), and the GrafanaDashboard CRs applied in step 3 above tell Grafana to load them. Once Grafana is installed, these dashboards appear automatically:

- **DOCA Platform DPU Fleet Health** — fleet-wide DPU health, provisioning state, version distribution.
- **DOCA Platform DPU Health Detail** — per-DPU status, conditions, and history timelines.
- **DOCA Platform Framework State** — inventory and readiness of every DPF resource type.
- **DOCA Platform Framework Performance** — how long DPF resources take to reach their conditions (reconcile/provisioning timings).
- **Controller Runtime** — DPF controller internals (CPU/memory, reconcile rates, queues, errors).

**Note**: These dashboards require Grafana — they are not visible in the native OpenShift console. In the automated deployment, they are installed by `scripts/post-install.sh observability` along with the rest of the Grafana stack.

---

# Chapter 11: Basic Troubleshooting

This chapter provides troubleshooting procedures for common issues encountered during DPF deployment and operation.

## 11.1 DPU Provisioning

**Symptom**: DPU remains in `Provisioning` phase for more than 30 minutes.

Diagnostic steps:

```bash
# Check DPU status
$ oc get dpus -n dpf-operator-system -o yaml

# Check the provisioning controller logs
$ oc logs -n dpf-operator-system deployment/dpf-operator-controller-manager \
    --container provisioning-controller

# Check the host-agent on the worker node
$ oc debug node/<WORKER_NODE> -- journalctl -u dpf-host-agent
```

Common causes:
- BFB download failed -- check BFB resource status and URL accessibility
- Network connectivity between host and DPU management interface
- Firmware update timeout -- the default `dmsTimeout` is 900 seconds
- Incorrect NVConfig parameters in DPUFlavor

## 11.2 DPU Object State

**Symptom**: DPF Operator pods are in `CrashLoopBackOff` or `Error` state.

Diagnostic steps:

```bash
$ oc logs -n dpf-operator-system deployment/dpf-operator-controller-manager
$ oc describe pod -n dpf-operator-system -l app.kubernetes.io/name=dpf-operator
```

Common causes:
- Missing pull secret -- verify `dpf-pull-secret` exists and has valid credentials
- CRD conflicts -- check if older DPF CRDs exist from a previous installation
- Maintenance Operator CRD missing -- ensure `maintenance-oc-crd.yaml` was applied

## 11.3 Management Cluster Nodes State

**Symptom**: Worker nodes are not labeled with `k8s.ovn.org/dpu-host=""`.

Diagnostic steps:

```bash
$ oc get nodes -l k8s.ovn.org/dpu-host
$ oc get mcp worker -o jsonpath='{.status.conditions}'
```

Common causes:
- Worker MachineConfig not applied -- check MCP status
- MachineConfig conflict -- verify no other MachineConfigs modify the kubelet service

**Symptom**: VFs are not being added to the `br-dpu` bridge on worker nodes.

Diagnostic steps:

```bash
$ oc debug node/<WORKER_NODE>
sh-5.1# chroot /host
sh-5.1# systemctl status vf-bridge-monitor.service
sh-5.1# journalctl -u vf-bridge-monitor.service
sh-5.1# ip link show master br-dpu
```

**Symptom**: Worker nodes are not getting the `feature.node.kubernetes.io/dpu-enabled` label.

Diagnostic steps:

```bash
$ oc get nodefeaturediscovery nfd -n openshift-nfd -o yaml
$ oc get pods -n openshift-nfd -l app.kubernetes.io/component=worker
$ oc logs -n openshift-nfd $(oc get pods -l app.kubernetes.io/component=worker -o name | head -1)
```

Common causes:
- NFD worker pod not running on the target node
- Incorrect PCI device IDs in the NodeFeatureRule
- `KUBERNETES_SERVICE_HOST` environment variable incorrect in NFD CR

## 11.4 dpf-hcp-provisioner-operator Issues

**Symptom**: The HostedCluster created by dpf-hcp-provisioner-operator is not becoming Available.

Diagnostic steps:

```bash
# Check HostedCluster status
$ oc get hostedcluster -n $CLUSTERS_NAMESPACE -o yaml

# Check the provisioner operator logs
$ oc logs -n dpf-hcp-provisioner-system deployment/dpf-hcp-provisioner-controller-manager

# Check etcd storage
$ oc get pvc -n ${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}

# Check HyperShift operator
$ oc get pods -n hypershift
```

Common causes:
- Insufficient storage for etcd PVCs
- Missing or invalid pull secret
- MetalLB not configured -- verify MetalLB pods are running
- VIP address conflict -- ensure `virtualIP` is available

**Symptom**: OVN-Kubernetes pods are in `CrashLoopBackOff` on the hosted cluster.

Diagnostic steps:

```bash
$ KUBECONFIG=/tmp/hosted-kubeconfig oc logs -n dpf-operator-system \
    $(oc get pods -l app=ovn-kubernetes-node -o name | head -1)

# Check OVN credential secret
$ oc get secret ovn-dpu -n dpf-operator-system
```

Common causes:
- Invalid OVN credential token -- check the DPUServiceCredentialRequest
- Incorrect `k8sAPIServer` in OVN configuration -- must point to management cluster API
- SCC not properly configured -- verify ClusterRoleBindings from section 8.5

**Collecting Debug Information**

For comprehensive debugging, collect the following information:

```bash
# DPF Operator logs
$ oc adm inspect namespace/dpf-operator-system --dest-dir=/tmp/dpf-debug

# Management cluster must-gather
$ oc adm must-gather --dest-dir=/tmp/must-gather

# Hosted cluster status (if accessible)
$ KUBECONFIG=/tmp/hosted-kubeconfig oc adm must-gather --dest-dir=/tmp/hosted-must-gather

# DPU-specific information
$ oc get dpus,dpusets,dpudeployments,dpuflavors,bfbs -n dpf-operator-system -o yaml > /tmp/dpu-resources.yaml
$ oc get dpuservicetemplates,dpuserviceconfigurations,dpuserviceinterfaces,dpuserviceipams -n dpf-operator-system -o yaml > /tmp/dpu-services.yaml
```

---

# Chapter 12: Appendix

## 12.1 Unsupported OVN Kubernetes Features

The following OVN-Kubernetes features are not supported when using DPF DPU offloading in this release:

- EgressIP
- EgressFirewall
- EgressQoS
- EgressService
- AdminNetworkPolicy / BaselineAdminNetworkPolicy
- Hybrid overlay
- IPsec
- Multi-homing (secondary networks)
- Hardware offload via the standard OVN-K path (DPF provides its own offload path)

## 12.2 Complete Resource Application Order

For reference, the following is the recommended order for applying all resources:

1. **Day-0 / Cluster Installation**
   - `network-node-identity` ConfigMap
   - Standard OVNKubernetes network configuration

2. **MachineConfigs** (triggers node reboots)
   - `99-nvidia-ovn-changes-master.yaml`
   - `99-nvidia-ovn-changes-worker.yaml`
   - `99-worker-bridge.yaml`
   - `99-worker-vf-bridge-monitor.yaml`

3. **FeatureGate**
   - MutatingAdmissionPolicy

4. **Namespace**
   - `dpf-operator-system`

5. **Operators** (order independent)
   - cert-manager
   - NFD
   - SR-IOV Network Operator
   - MetalLB
   - GitOps / ArgoCD
   - MCE / HyperShift

6. **Operator Configuration**
   - NFD CR and NodeFeatureRule
   - SR-IOV Operator Config
   - MetalLB instance CR
   - ArgoCD configuration
   - CNO IP forwarding

7. **dpf-hcp-provisioner-operator**
   - Operator Helm install
   - Secrets (pull-secret, ssh-key)
   - DPUCluster
   - DPFHCPProvisioner

8. **DPF Operator**
   - Pull secrets and NGC secrets
   - Maintenance Operator CRD
   - DPF Operator Helm install
   - DPFOperatorConfig
   - NodeSRIOVDevicePluginConfig

9. **DPU Service Resources**
   - BFB
   - DPUFlavor
   - DPUServiceIPAM (pool1, loopback)
   - DPUServiceInterfaces (physical, OVN, HBN)
   - Service credentials (OVN)
   - DPUServiceTemplates (HBN, OVN, DTS)
   - DPUServiceConfigurations (HBN, OVN, DTS)
   - NetworkPolicy
   - DPUDeployment

10. **OVN-K Adjustments**
    - `ovn-kubernetes` namespace
    - OVN-K Resource Injector
    - CNO DPU-host mode ConfigMap

11. **Worker Nodes**
    - Scale workers
    - Approve CSRs
    - Monitor DPU provisioning
    - SCC ClusterRoleBindings on hosted cluster

## 12.3 Environment Variables Quick Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `CLUSTER_NAME` | Management cluster name | `mycluster` |
| `BASE_DOMAIN` | Base DNS domain | `example.com` |
| `HOST_CLUSTER_API` | Management cluster API FQDN | `api.mycluster.example.com` |
| `TAG` | DPF version tag | `v26.4.0` |
| `TARGETCLUSTER_API_SERVER_PORT` | API server port | `6443` |
| `TARGETCLUSTER_NODE_CIDR` | DPU node network CIDR | `10.0.0.0/16` |
| `NFS_SERVER_IP` | NFS server IP for BFB storage | `192.168.1.10` |
| `NFS_BFB_PATH` | NFS export path for BFB images | `/exports/bfb` |
| `POD_CIDR` | Management cluster pod CIDR | `10.128.0.0/14` |
| `SERVICE_CIDR` | Management cluster service CIDR | `172.30.0.0/16` |
| `VTEP_CIDR` | VTEP network for HBN/OVN | `192.168.200.0/29` |
| `NUM_VFS` | Number of VFs per PF | `46` |
| `REGISTRY` | NVIDIA Helm chart registry | `https://helm.ngc.nvidia.com/nvidia/doca` |
| `HBN_NGC_IMAGE_URL` | HBN container image | `nvcr.io/nvidia/doca/doca_hbn:3.2.0-doca3.2.0` |
| `BFB_URL` | BFB image download URL | `https://content.mellanox.com/...` |
| `OVN_TEMPLATE_CHART_URL` | OVN Helm chart OCI URL | `oci://ghcr.io/mellanox/charts` |
| `OVN_CHART_VERSION` | OVN chart version | `v26.4.0-ocpbeta` |
| `HOSTED_CLUSTER_NAME` | Hosted DPU cluster name | `dpf-hosted` |
| `HOSTED_CLUSTER_VIP` | Virtual IP for hosted API | `192.168.1.200` |
| `ETCD_STORAGE_CLASS` | Storage class for etcd | `lvms-vg1` |
| `OCP_RELEASE_IMAGE` | OCP release image | `quay.io/openshift-release-dev/ocp-release:4.22.0-multi` |
| `BLUEFIELD_OCP_IMAGE` | BlueField OCP image | `quay.io/eelgaev/bluefield-ocp:4.21.0_3.4.0-beta-v2` |

---

**Document End**
