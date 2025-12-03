# OpenShift DPF Automation - User Guide

Welcome to the OpenShift DPF automation system! This guide will help you deploy NVIDIA DPF (DPU Platform Framework) on Red Hat OpenShift with complete automation from cluster creation to DPU services.

## What This Automation Does

This automation handles the complete deployment lifecycle:

1. **Creates OpenShift clusters** using Red Hat Assisted Installer
2. **Deploys NVIDIA DPF operator** with all prerequisites
3. **Sets up DPU-accelerated networking** with OVN-Kubernetes
4. **Provisions worker nodes** automatically via Bare Metal Operator
5. **Configures DPU services** for production workloads

## Quick Navigation

| Document | Purpose | When to Use |
|----------|---------|-------------|
| **[Getting Started](getting-started.md)** | Complete setup guide | First-time users |
| **[Configuration Guide](configuration.md)** | Environment variables reference | Customizing deployments |
| **[Deployment Scenarios](deployment-scenarios.md)** | SNO, multi-node, and production setups | Choosing deployment type |
| **[Worker Provisioning](worker-provisioning.md)** | Adding worker nodes with DPUs | Scaling clusters |
| **[Troubleshooting](troubleshooting.md)** | Common issues and solutions | When things go wrong |
| **[Advanced Topics](advanced-topics.md)** | Performance tuning and customization | Power users |

## Supported Deployment Types

### Single-Node OpenShift (SNO)
- **Use Case**: Development, testing, edge computing
- **Resources**: 1 VM or bare-metal node
- **Time**: ~2 hours from start to finish
- **Storage**: Local volumes (LVMS)

### Multi-Node Cluster
- **Use Case**: Production environments
- **Resources**: 3+ control plane nodes
- **Time**: ~3 hours from start to finish
- **Storage**: Distributed storage (ODF)

### With Worker Nodes
- **Use Case**: Production with DPU acceleration
- **Resources**: Control plane + worker nodes with NVIDIA BlueField-3 DPUs
- **Time**: +15 minutes per worker node
- **Features**: Automated provisioning via BMC/Redfish

## Prerequisites Overview

Before starting, you'll need:

- **Host System**: RHEL 8/9 or compatible Linux
- **Hardware**: 64GB+ RAM for multi-node clusters
- **Network**: Internet access for image downloads
- **Credentials**: Red Hat and NVIDIA registry access
- **Tools**: aicli, oc, helm (installation automated)

## Quick Start for Impatient Users

```bash
# 1. Clone and configure
git clone <repository-url>
cd openshift-dpf
cp .env.example .env
# Edit .env with your settings

# 2. Add your credentials
cp ~/Downloads/openshift-pull-secret.json openshift_pull.json
# Add NGC credentials to pull-secret.txt

# 3. Deploy everything
make all

# 4. Check status
oc get nodes
oc get pods -n dpf-operator-system
```

**⚠️ Warning**: The quick start uses defaults that may not match your environment. Read the [Getting Started](getting-started.md) guide for proper setup.

## Support and Community

- **Issues**: Report problems in the repository issues
- **Documentation**: This guide covers common scenarios
- **Updates**: Check for new releases and documentation updates

---

**Next Step**: Start with [Getting Started](getting-started.md) for complete setup instructions.