# Deployment Scenarios

This guide explains the different deployment scenarios supported by the OpenShift DPF automation, helping you choose the right approach for your environment.

## Overview

The automation supports three primary deployment scenarios:

1. **Single-Node OpenShift (SNO)** - Development and edge computing
2. **Multi-Node Cluster** - Production environments
3. **Production with Workers** - Full-scale DPU acceleration

Each scenario has different resource requirements, storage configurations, and use cases.

## Single-Node OpenShift (SNO)

### When to Use SNO

- **Development and testing** of DPF applications
- **Edge computing** scenarios with resource constraints
- **Proof of concepts** and demonstrations
- **Learning** DPF concepts without full infrastructure

### SNO Configuration

```bash
# Basic SNO Configuration (.env)
VM_COUNT=1
RAM=32768                     # 32GB minimum for production workloads
VCPUS=16                      # 16 vCPUs recommended
DISK_SIZE1=120               # Primary disk
DISK_SIZE2=80                # Secondary disk for container storage

# No VIP addresses needed for SNO
# API_VIP and INGRESS_VIP are not required

# Storage automatically configures to LVMS
ETCD_STORAGE_CLASS=lvms-vg1
```

### SNO Deployment Process

```bash
# 1. Configure for SNO
echo "VM_COUNT=1" >> .env

# 2. Deploy complete stack
make all

# 3. Monitor deployment (opens new terminal)
watch 'oc get nodes && echo "--- Cluster Status ---" && aicli list clusters'
```

### SNO Characteristics

| Aspect | Configuration |
|--------|---------------|
| **Control Plane** | Single node acts as both control plane and worker |
| **Storage** | Local Volume Manager Storage (LVMS) |
| **High Availability** | None - single point of failure |
| **Resource Usage** | Minimum viable for DPF development |
| **Hypershift Mode** | SingleReplica for hosted cluster |
| **Typical Deployment Time** | 1.5-2 hours |

### SNO Resource Planning

```bash
# Development Environment
RAM=16384                    # 16GB - minimum for basic testing
VCPUS=8                      # 8 vCPUs - sufficient for development

# Production Edge Deployment
RAM=32768                    # 32GB - recommended for edge workloads
VCPUS=16                     # 16 vCPUs - better performance
```

## Multi-Node Cluster

### When to Use Multi-Node

- **Production environments** requiring high availability
- **Performance testing** with realistic resource allocation
- **Distributed workloads** that benefit from multiple nodes
- **Storage testing** with distributed storage (ODF)

### Multi-Node Configuration

```bash
# Multi-Node Configuration (.env)
VM_COUNT=3                   # 3 control plane nodes minimum
RAM=32768                    # 32GB per node
VCPUS=16                     # 16 vCPUs per node

# Required VIP addresses (must be available on your network)
API_VIP=10.1.150.100         # API server VIP
INGRESS_VIP=10.1.150.101     # Ingress router VIP

# Network configuration
POD_CIDR=10.128.0.0/14       # Pod network range
SERVICE_CIDR=172.30.0.0/16   # Service network range

# Storage automatically configures to ODF
ETCD_STORAGE_CLASS=ocs-storagecluster-ceph-rbd
```

### Multi-Node Deployment Process

```bash
# 1. Configure VIP addresses (critical step)
# Ensure these IPs are available and not assigned
ping ${API_VIP}              # Should fail - IP not in use
ping ${INGRESS_VIP}          # Should fail - IP not in use

# 2. Set multi-node configuration
echo "VM_COUNT=3" >> .env
echo "API_VIP=10.1.150.100" >> .env
echo "INGRESS_VIP=10.1.150.101" >> .env

# 3. Deploy complete stack
make all

# 4. Monitor all nodes
watch 'oc get nodes -o wide'
```

### Multi-Node Characteristics

| Aspect | Configuration |
|--------|---------------|
| **Control Plane** | 3 nodes in HA configuration |
| **Storage** | OpenShift Data Foundation (ODF) distributed storage |
| **High Availability** | Full HA with etcd clustering |
| **Resource Usage** | Production-ready resource allocation |
| **Hypershift Mode** | HighlyAvailable for hosted cluster |
| **Typical Deployment Time** | 2.5-3 hours |

### Multi-Node Resource Planning

```bash
# Total Host Requirements for 3-node cluster
Total RAM: 96GB minimum (32GB × 3 nodes)
Total vCPUs: 48 minimum (16 × 3 nodes)
Total Storage: 600GB minimum ((120+80) × 3 nodes)

# Network Requirements
- 2 unused IP addresses for VIPs
- Network access between host and VIP subnet
- DNS resolution for cluster domain
```

## Production with Workers (DPU Acceleration)

### When to Use Production with Workers

- **Full DPU acceleration** with NVIDIA BlueField-3 DPUs
- **Production workloads** requiring dedicated worker nodes
- **High-performance networking** with SR-IOV and OVN acceleration
- **Scalable deployments** with worker node provisioning automation

### Production Configuration

```bash
# Production with Workers (.env)
VM_COUNT=3                   # Control plane nodes
WORKER_COUNT=2               # Number of worker nodes to provision

# Control plane configuration
RAM=32768                    # 32GB per control plane node
VCPUS=16                     # 16 vCPUs per control plane node

# VIP configuration
API_VIP=10.1.150.100
INGRESS_VIP=10.1.150.101

# Worker provisioning configuration
AUTO_APPROVE_WORKER_CSR=false    # Recommended for production security

# Worker 1 Configuration
WORKER_1_NAME=openshift-worker-1
WORKER_1_BMC_IP=192.168.1.101
WORKER_1_BMC_USER=root
WORKER_1_BMC_PASSWORD=calvin
WORKER_1_BOOT_MAC=aa:bb:cc:dd:ee:01
WORKER_1_ROOT_DEVICE=/dev/sda

# Worker 2 Configuration
WORKER_2_NAME=openshift-worker-2
WORKER_2_BMC_IP=192.168.1.102
WORKER_2_BMC_USER=root
WORKER_2_BMC_PASSWORD=calvin
WORKER_2_BOOT_MAC=aa:bb:cc:dd:ee:02
WORKER_2_ROOT_DEVICE=/dev/sda

# DPU Configuration
DPU_INTERFACE=ens7f0np0         # Physical DPU interface
DPU_OVN_VF=ens7f0v1           # OVN virtual function
NUM_VFS=46                    # Number of virtual functions
```

### Production Deployment Process

```bash
# 1. Deploy control plane first
make create-cluster create-vms cluster-install deploy-dpf

# 2. Deploy DPU services
make deploy-dpu-services

# 3. Add worker nodes (requires physical hardware)
make add-worker-nodes

# 4. Monitor worker provisioning
watch 'oc get bmh -n openshift-machine-api'
watch 'oc get nodes'

# 5. Approve CSRs (if not auto-approving)
oc get csr | grep Pending
oc adm certificate approve <csr-name>
```

### Production Characteristics

| Aspect | Configuration |
|--------|---------------|
| **Architecture** | Control plane VMs + Physical worker nodes with DPUs |
| **Worker Provisioning** | Automated via BMO and Redfish |
| **DPU Acceleration** | Full OVN-Kubernetes acceleration on workers |
| **Storage** | ODF on control plane, local storage on workers |
| **Security** | Manual CSR approval recommended |
| **Typical Deployment Time** | 3-4 hours (including worker provisioning) |

## Quick Scenario Guide

- **SNO**: Learning/development, 32GB+ RAM, no VIPs needed
- **Multi-Node**: Production HA, 64GB+ RAM, requires VIP addresses
- **Production**: Full DPU acceleration, 64GB+ RAM, requires physical worker nodes

## Storage Notes

- **SNO**: Uses Local Volume Manager Storage (LVMS) automatically
- **Multi-Node**: Uses OpenShift Data Foundation (ODF) automatically
- **Production**: Configure custom storage classes if needed in `.env`

## Next Steps

- **First deployment**: Start with [Getting Started](getting-started.md) guide
- **Configuration details**: See [Configuration Guide](configuration.md)
- **Worker provisioning**: See [Worker Provisioning](worker-provisioning.md)
- **Troubleshooting**: See [Troubleshooting Guide](troubleshooting.md)

Choose your deployment scenario and follow the appropriate configuration and deployment process. Each scenario builds in complexity, so starting with SNO for learning is recommended.