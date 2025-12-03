# Configuration Guide

Environment variable reference for OpenShift DPF automation. All configuration is done through the `.env` file.

## Quick Start Configuration

```bash
# Start with the example
cp .env.example .env

# Edit essential settings
nano .env

# Most common settings to change:
CLUSTER_NAME=my-dpf-cluster
BASE_DOMAIN=example.com
OPENSHIFT_VERSION=4.20.0
```

**💡 Essential Setup**: Only these settings are required for basic deployment. Advanced options are documented below for customization.

## Essential Configuration

### Cluster Settings (Required)

```bash
# Cluster Identity
CLUSTER_NAME=my-dpf-cluster              # Must be DNS-safe, unique
BASE_DOMAIN=example.com                  # Your registered domain
OPENSHIFT_VERSION=4.20.0                 # Supported versions: 4.20.x

# Credentials (Required)
OPENSHIFT_PULL_SECRET=openshift_pull.json   # Red Hat pull secret
DPF_PULL_SECRET=pull-secret.txt             # NGC registry credentials
SSH_KEY=~/.ssh/id_rsa                       # SSH key for access
```

### VM Resources (Adjust for your hardware)

```bash
# VM Configuration
VM_COUNT=3                    # 1 for SNO, 3+ for multi-node
RAM=41984                     # RAM per VM (MB) - 32GB minimum
VCPUS=14                      # CPU cores per VM
DISK_SIZE1=120                # Primary disk (GB)
DISK_SIZE2=80                 # Secondary disk (GB)
```

### Network Settings (Usually keep defaults)

```bash
# Cluster Network
API_VIP=10.1.150.100         # Cluster API IP
INGRESS_VIP=10.1.150.101     # Ingress IP
POD_CIDR=10.128.0.0/14       # Pod network range
SERVICE_CIDR=172.30.0.0/16   # Service network range
```

## DPF Configuration

### Basic DPF Settings

```bash
# DPF Operator
DPF_VERSION=v25.7.1                    # DPF version
DPF_HELM_REPO_URL=https://helm.ngc.nvidia.com/nvidia/doca/dpf-operator

# OVN Chart (auto-configured)
OVN_CHART_VERSION=v25.7.1-f073927     # Matches DPF version
```

### DPU Network Configuration

```bash
# DPU Interface Settings
DPU_INTERFACE=ens7f0np0               # Physical DPU interface
DPU_OVN_VF=ens7f0v1                  # OVN virtual function
NUM_VFS=46                            # Number of SR-IOV VFs
DPU_HOST_CIDR=10.6.130.0/24          # DPU host network
HBN_OVN_NETWORK=10.6.150.0/27        # HBN network range
```

## Worker Provisioning

### Worker Node Configuration

```bash
# Number of workers to provision
WORKER_COUNT=0                        # 0 = no workers, 1+ = provision workers

# Worker 1 Example (copy pattern for additional workers)
WORKER_1_NAME=worker-01               # Unique hostname
WORKER_1_BMC_IP=192.168.1.101         # BMC IP address
WORKER_1_BMC_USER=admin               # BMC username (secure credentials!)
WORKER_1_BMC_PASSWORD=your_password   # BMC password
WORKER_1_BOOT_MAC=aa:bb:cc:dd:ee:01   # PXE boot interface MAC
WORKER_1_ROOT_DEVICE=/dev/sda         # Installation disk (optional)

# Security Settings
AUTO_APPROVE_WORKER_CSR=false         # Manual approval (recommended)
CSR_APPROVAL_TIMEOUT=600              # Approval timeout (seconds)
```

## Deployment Scenarios

### Single-Node OpenShift (SNO)

```bash
# Minimal resource setup
VM_COUNT=1
RAM=32768                             # 32GB minimum for SNO
VCPUS=8
ISO_TYPE=minimal
```

### Multi-Node Production

```bash
# Production-ready cluster
VM_COUNT=5                            # 3 control + 2 workers
RAM=65536                             # 64GB for production nodes
VCPUS=16
```

### Development Environment

```bash
# Resource-optimized for development
VM_COUNT=1
RAM=32768
VCPUS=8
AUTO_APPROVE_WORKER_CSR=true          # Skip manual steps in dev
```

## Advanced Configuration

### Performance Tuning

```bash
# Network Optimization
NODES_MTU=9000                        # Enable jumbo frames
BRIDGE_NAME=br-dpf                    # Custom bridge name

# Storage Optimization
ISO_TYPE=minimal                      # Faster boot with minimal ISO
```

### Hypershift Settings

```bash
# Hosted Cluster Configuration
HYPERSHIFT_IMAGE=quay.io/hypershift/hypershift-operator:latest
HOSTED_CLUSTER_NAME=doca              # Hosted cluster name
CLUSTERS_NAMESPACE=clusters           # Management namespace
OCP_RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.20.0-multi
```

### Custom Registry

```bash
# Private Registry Support
PRIVATE_REGISTRY=registry.example.com
# Update pull secrets with your registry credentials
```

## Configuration Validation

### Verify Your Configuration

```bash
# Check for common issues
make validate-environment

# Verify required variables
grep -E "CLUSTER_NAME|BASE_DOMAIN|OPENSHIFT_VERSION" .env

# Check for syntax errors
bash -n .env
```

### Common Configuration Issues

| Issue | Symptom | Fix |
|-------|---------|-----|
| Trailing spaces in values | "Invalid parameter" errors | Remove spaces: `CLUSTER_NAME=value` |
| Empty required variables | Missing configuration errors | Set all required variables |
| Invalid IP ranges | Network conflicts | Use non-overlapping network ranges |
| Wrong pull secret format | Image pull failures | Re-download pull secrets |

## Environment Variables Reference

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `CLUSTER_NAME` | Cluster identifier | `my-dpf-cluster` |
| `BASE_DOMAIN` | DNS domain | `example.com` |
| `OPENSHIFT_VERSION` | OpenShift version | `4.20.0` |
| `OPENSHIFT_PULL_SECRET` | Red Hat pull secret file | `openshift_pull.json` |
| `DPF_PULL_SECRET` | NGC registry credentials | `pull-secret.txt` |

### Commonly Changed Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VM_COUNT` | Number of VMs | `3` |
| `RAM` | RAM per VM (MB) | `41984` |
| `VCPUS` | CPU cores per VM | `14` |
| `DPF_VERSION` | DPF operator version | `v25.7.1` |
| `WORKER_COUNT` | Number of workers | `0` |

### Optional Variables (Keep defaults unless needed)

All other variables in `.env.example` have sensible defaults. Only change them if you need specific customization.

## Version Compatibility

| OpenShift | DPF | Status |
|-----------|-----|--------|
| 4.20.x | v25.7.1 | ✅ Only supported version |

## Configuration Examples

### Production Example

```bash
CLUSTER_NAME=prod-dpf-cluster
BASE_DOMAIN=company.com
OPENSHIFT_VERSION=4.20.0
VM_COUNT=5
RAM=65536
VCPUS=16
WORKER_COUNT=2
AUTO_APPROVE_WORKER_CSR=false
```

### Lab/Development Example

```bash
CLUSTER_NAME=dev-dpf-cluster
BASE_DOMAIN=lab.internal
OPENSHIFT_VERSION=4.20.0
VM_COUNT=1
RAM=32768
VCPUS=8
WORKER_COUNT=0
AUTO_APPROVE_WORKER_CSR=true
```

## Next Steps

- **New Users**: Start with [Getting Started](getting-started.md)
- **Deployment**: Choose your scenario in [Deployment Scenarios](deployment-scenarios.md)
- **Workers**: Add worker nodes with [Worker Provisioning](worker-provisioning.md)
- **Optimization**: Advanced settings in [Advanced Topics](advanced-topics.md)

**Remember**: Start with the defaults in `.env.example` and only change what you need. Most deployments work with minimal configuration changes.