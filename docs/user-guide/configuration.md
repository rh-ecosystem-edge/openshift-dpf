# Configuration Guide

Environment variable reference for the OpenShift DPF and NNO automation. All configuration is done through the `.env` file.

## Quick Start Configuration

```bash
# Start with the example
cp .env.example .env

# Edit essential settings
nano .env

# Most common settings to change (DPF is the default profile):
CLUSTER_NAME=my-dpf-cluster
BASE_DOMAIN=example.com
OPENSHIFT_VERSION=4.20.0
```

**💡 Essential Setup**: Only these settings are required for basic deployment. Advanced options are documented below for customization.

## Essential Configuration

### Deployment Profile

```bash
DEPLOYMENT_PROFILE=dpf  # dpf or nno; defaults to dpf
```

The `dpf` profile retains the complete existing deployment. The `nno` profile
creates a base OpenShift cluster while skipping the DPF pull secret, DPU
network inputs, NFD operator, cert-manager, DPU worker manifests, and DPF
hosted-cluster storage. See [NNO Base Cluster](nno-base-cluster.md).

### Cluster Settings (Required)

```bash
# Cluster Identity
CLUSTER_NAME=my-dpf-cluster              # Must be DNS-safe, unique
BASE_DOMAIN=example.com                  # Your registered domain
OPENSHIFT_VERSION=4.20.0                 # Supported versions: 4.20.x

# Credentials (Required)
OPENSHIFT_PULL_SECRET=openshift_pull.json   # Red Hat pull secret
DPF_PULL_SECRET=pull-secret.txt             # NGC registry credentials (dpf only)
SSH_KEY=~/.ssh/id_ed25519                   # SSH key for access
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

### Remote Libvirt Host (Optional)

Run the automation locally while hosting VMs on a remote machine:

```bash
LIBVIRT_HOST=root@192.168.1.100   # Remote libvirt host (SSH user@host)
```

When set, the automation will:
- Connect to libvirt via `qemu+ssh://` URI
- Download ISOs directly on the remote host (via SSH + curl)
- Create and manage the network bridge on the remote host
- `DISK_PATH` and `ISO_FOLDER` refer to paths on the remote host

**Prerequisites**: SSH key-based authentication must be configured to the remote host, and `libvirtd` must be running there.

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

# OVN Chart (oci://ghcr.io/mellanox/charts/ovn-kubernetes-chart)
OVN_CHART_VERSION=v26.4.1-ocp-release-v4.22   # Align with DPF 26.4.x on OCP 4.22
```

### DPU Network Configuration

```bash
# DPU Interface Settings
DPU_INTERFACE=ens7f0np0               # Physical DPU interface
NUM_VFS=46                            # Number of SR-IOV VFs
DPU_HOST_CIDR=10.6.130.0/24          # DPU host network
VTEP_CIDR=10.6.150.0/27              # OVN-Kubernetes VTEPs on the high-speed fabric
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

# CSR Auto-Approval (deploy CronJobs to approve certificates)
AUTO_APPROVE_WORKER_CSR=false         # Host cluster workers (recommended: false)

# BareMetalHost inspection (skip by default to shorten CI/lab worker provisioning)
BMH_ENABLE_INSPECTION=false           # true = agent-based hardware discovery before install
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

### Zero Trust tenant HostedCluster (three-cluster flow)

After `make all-zt`, `make deploy-zt-tenant-cluster` provisions a **second** HostedCluster on the **same physical servers** that host the DPUs (one tenant worker per server). It uses **MultiCluster Engine** (Assisted Service + shared HyperShift operator), an Agent-platform **NodePool**, **InfraEnv**, and **BareMetalHost** objects in the tenant hosted control plane namespace (`${CLUSTERS_NAMESPACE}-${ZT_TENANT_CLUSTER_NAME}`). The DPU HostedCluster stays owned by **DPFHCPProvisioner**; the tenant cluster is separate, with its own kubeconfig (`ZT_TENANT_KUBECONFIG`, default `tenant.kubeconfig`).

**CI / env requirements (in addition to Zero Trust worker + DPU inventory):**

- **`HYPERSHIFT_INSTALL_METHOD=mce`** — the default for every flow: Zero Trust installs HyperShift through MultiCluster Engine. `binary` installs the HyperShift operator from the CLI/operator image instead, but the tenant phase (`make deploy-zt-tenant-cluster` or `ZT_DEPLOY_TENANT_CLUSTER=true`) requires `mce`, because the tenant runs on MCE's shared HyperShift and Assisted Service.
- **`ZT_DEPLOY_TENANT_CLUSTER`** — `true` makes `make all-zt` end by deploying the tenant HostedCluster, so one command completes the whole three-cluster flow. Default `false`, which leaves `make all-zt` unchanged and the tenant as a separate `make deploy-zt-tenant-cluster`. When enabled, `all-zt` runs `make validate-zt-tenant-config` first, so a bad tenant variable fails before the cluster work instead of an hour into the deployment, and it requires `HYPERSHIFT_INSTALL_METHOD=mce`, the default.
- **`ZT_TENANT_CLUSTER_NAME`** / **`ZT_TENANT_KUBECONFIG`** — tenant HostedCluster name and kubeconfig path (defaults: `tenant`, `tenant.kubeconfig`).
- **`ZT_TENANT_BASE_DOMAIN`** — DNS base domain for the tenant API hosts (lowercase DNS name, no scheme, no trailing dot; default: `BASE_DOMAIN`). HyperShift prefixes the hosts with the tenant cluster name, so sharing the management cluster's domain is safe as long as `ZT_TENANT_CLUSTER_NAME` differs from `HOSTED_CLUSTER_NAME`.
- **`ZT_TENANT_CLUSTER_NETWORK_CIDR`** / **`ZT_TENANT_SERVICE_NETWORK_CIDR`** — guest pod and service networks for the tenant cluster. Defaults are the HyperShift defaults (`10.128.0.0/14`, `172.30.0.0/16`); the tenant is a separate cluster, so they may match the management cluster's `POD_CIDR`/`SERVICE_CIDR`. Override only if you need distinct ranges.
- **`ZT_TENANT_PULL_SECRET_NAME`** — name of the pull secret in the tenant hosted control plane namespace (matches `InfraEnv.spec.pullSecretRef`; default `zt-tenant-pull-secret`).
- **Machine network** — not configurable. The tenant `HostedCluster` is created without a machine network (`--machine-cidr`), so HyperShift/Assisted derive it from the worker network discovered at install time.
- **Tenant release image** — `hypershift create cluster|nodepool agent --release-image` uses **`OCP_RELEASE_IMAGE`** (same as management and DPU hosted cluster). Override only when the tenant must run a different version: add `ZT_TENANT_OCP_RELEASE_IMAGE=...` to `.env` by hand. MCE Assisted must expose matching discovery images via **`AgentServiceConfig`** / **assisted-image-service** for the configured architecture.
- **`ZT_TENANT_RHCOS_CPU_ARCHITECTURE`** — **`x86_64`** (default) or **`aarch64`**. The tenant flow derives the Assisted osImage architecture (`x86_64`/`arm64`) and the HyperShift NodePool architecture (`amd64`/`arm64`) from it, and auto-fills `ZT_TENANT_RHCOS_ISO_URL`, `ZT_TENANT_RHCOS_ROOTFS_URL` and `ZT_TENANT_RHCOS_VERSION` from `mirror.openshift.com` for the matching tree. There is no multi-arch discovery image.
- **`AgentServiceConfig`** — created only when `agentserviceconfig/agent` does not exist in `multicluster-engine` (MCE ships without one). It is pinned to **`ETCD_STORAGE_CLASS`** for its database and filesystem PVCs and omits `imageStorage`, so assisted-image-service uses an ephemeral `emptyDir`. An existing `AgentServiceConfig` is used as-is.
- **`capi-provider-role`** — the script applies this Role (`agent-install.openshift.io`/`agents`, verbs `*`) to the tenant agent namespace before creating the `HostedCluster`. The HyperShift operator creates the `cluster-api-agent-<control-plane-namespace>` RoleBinding but does not create the Role it binds: older CLIs emitted it, and openshift/hypershift#8305 moved that to newer operators, which name it `capi-provider-role-<control-plane-namespace>`. When the CLI and the MCE operator come from different generations nothing creates the Role, and the `HostedCluster` stays at `PlatformCredentialsFound=False` with `failed to reconcile Agent RoleBinding: rolebindings.rbac.authorization.k8s.io "capi-provider-role" not found`. The extra Role is inert with operators that no longer reference it. Re-running the target heals an already-stuck `HostedCluster`.

**Bare-metal discovery (Agent install, not DataImage):**

Agent-based tenant workers use **`InfraEnv`** + **`BareMetalHost`** (labelled to the InfraEnv). Metal3 creates **`PreprovisioningImage`** per BMH with `status.imageUrl` pointing at **assisted-image-service** (`…/minimal.iso`). It does **not** create **`DataImage`** resources; empty `oc get dataimages.metal3.io -A` is expected.

**`PreprovisioningImage.spec` cannot override `imageUrl`** — only Assisted populates `status.imageUrl`. **`BareMetalHost` `disableCertificateVerification`** applies to **cluster → BMC Redfish** only; **iDRAC** still HTTPS-fetches `imageUrl` and must trust the **ingress** certificate (default router cert is self-signed — use `wget --no-check-certificate` or `curl -k` from a management host to validate reachability, not as proof iDRAC trusts the cert).

Lab checklist:

1. The BMC/L2 network can reach the discovery image host: DNS or split-horizon resolves `assisted-image-service-multicluster-engine.apps.<cluster-domain>` from the BMC subnet; firewall allows **443** to ingress (e.g. `10.6.135.135`).
2. **`PreprovisioningImage`** Ready and non-empty `status.imageUrl`; **`curl -vk`** that URL from the BMC VLAN.
3. **iDRAC**: import OpenShift **router CA** (`oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.ca-bundle\.crt}' | base64 -d`) or use ingress signed by a CA iDRAC already trusts; **Virtual Media Attach/Auto-Attach** enabled.
4. With **`provisioningNetwork: Disabled`**, discovery relies on **virtual media** (no PXE fallback).

`make deploy-zt-tenant-cluster` logs route host, each `PreprovisioningImage` URL, and router CA export after applying BMHs.

**Sequence:**

1. Complete `make all-zt` (DPU HostedCluster healthy; `DPFHCPProvisioner` Ready).
2. Run `make deploy-zt-tenant-cluster`. Before any cluster call it validates the whole tenant env surface (mode and install method, cluster/base-domain/object names, agent label key, both IPv4 CIDRs, RHCOS architecture (`x86_64`/`aarch64`), release version format, RHCOS mirror URL schemes, `ETCD_STORAGE_CLASS`, the `ZT_TENANT_KUBECONFIG` target (existing writable directory, distinct from the management kubeconfig), the DPU-host worker inventory, the SSH public (`.pub`) key, and the four RHCOS URL/version variables used by the `AgentServiceConfig` osImage). It then proceeds with idempotent skips for existing HostedCluster / BMH / NodePool where safe.

To run both phases in one command, set `ZT_DEPLOY_TENANT_CLUSTER=true` (in `.env` or on the command line) before `make all-zt`; it validates the tenant configuration first and the tenant phase comes after `verify-zt-deployment`. Every phase is idempotent, so a failed run can be resumed by repeating the same command.

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
| `DPF_PULL_SECRET` | NGC registry credentials (`dpf` only) | `pull-secret.txt` |

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

**Remember**: Start with the defaults in `.env.example` and only change what
you need. Most deployments work with minimal configuration changes.
