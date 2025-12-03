# OpenShift DPF Automation

Complete automation framework for deploying NVIDIA DPF (DPU Platform Framework) on Red Hat OpenShift clusters with NVIDIA BlueField-3 DPUs.

## 🚀 Quick Deployment

**One command does everything:**
```bash
make all
```

This handles the complete deployment lifecycle:
- Creates OpenShift clusters using Red Hat Assisted Installer
- Deploys NVIDIA DPF operator with all prerequisites
- Sets up DPU-accelerated networking with OVN-Kubernetes
- Provisions worker nodes automatically via Bare Metal Operator

## 📋 Prerequisites

### System Requirements
- **Host**: RHEL 8/9, 64GB+ RAM, 16+ CPU cores
- **Hardware**: NVIDIA BlueField-3 DPUs on worker nodes
- **Network**: Internet access, management and high-speed networks

### Required Tools
- [OpenShift CLI (`oc`)](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html)
- [Red Hat Assisted Installer CLI (`aicli`)](https://console.redhat.com/openshift/install)
- [Helm 3.x](https://helm.sh/docs/intro/install/)
- Standard tools: `jq`, `git`, `curl`

### Required Credentials
- **Red Hat Pull Secret**: Download from [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret)
- **Red Hat Offline Token**: Generate at [cloud.redhat.com/openshift/token](https://cloud.redhat.com/openshift/token)
- **NVIDIA NGC API Key**: Create at [NGC Portal](https://ngc.nvidia.com/) → Account → Setup

## 🏃 Quick Start

### 1. Clone and Setup
```bash
git clone https://github.com/rh-ecosystem-edge/openshift-dpf.git
cd openshift-dpf
cp .env.example .env
```

### 2. Configure Credentials
```bash
# Add Red Hat offline token
mkdir -p ~/.aicli
echo "YOUR_OFFLINE_TOKEN" > ~/.aicli/offlinetoken.txt

# Add OpenShift pull secret (downloaded from Red Hat)
cp ~/Downloads/openshift-pull-secret.json openshift_pull.json

# Create NGC pull secret
cat > pull-secret.txt << 'EOF'
{
  "auths": {
    "nvcr.io": {
      "username": "$oauthtoken",
      "password": "YOUR_NGC_API_KEY",
      "auth": "BASE64_ENCODED_CREDENTIALS"
    }
  }
}
EOF
```

### 3. Configure Deployment
```bash
# Edit .env file with your settings
nano .env

# Essential settings:
CLUSTER_NAME=my-dpf-cluster
BASE_DOMAIN=example.com
VM_COUNT=1                    # 1=SNO, 3+=Multi-node
DPF_VERSION=v25.7.1
```

### 4. Deploy Everything
```bash
make all
```
⏱️ **Takes 2-3 hours** - fully automated, no user interaction needed

## 📖 Documentation

| Guide | Purpose |
|-------|---------|
| **[Getting Started](docs/user-guide/getting-started.md)** | Step-by-step setup guide |
| **[Configuration](docs/user-guide/configuration.md)** | Environment variables |
| **[Worker Provisioning](docs/user-guide/worker-provisioning.md)** | Add physical worker nodes |
| **[Troubleshooting](docs/user-guide/troubleshooting.md)** | Fix common issues |

## ⚙️ Deployment Types

### Single-Node OpenShift (SNO)
Perfect for development and edge computing:
```bash
VM_COUNT=1
RAM=32768                     # 32GB recommended
make all
```

### Multi-Node Production
For high-availability environments:
```bash
VM_COUNT=3
API_VIP=10.1.150.100         # Required for multi-node
INGRESS_VIP=10.1.150.101     # Required for multi-node
make all
```

### Production with Workers
Full DPU acceleration with worker nodes:
```bash
WORKER_COUNT=2               # Number of physical worker nodes
# Configure WORKER_*_BMC_IP, WORKER_*_BMC_USER, etc.
make all
```

## 🛠️ Key Commands

### Complete Deployment
```bash
make all                     # Full automated deployment
```

### Individual Steps (optional)
```bash
make create-cluster          # Create OpenShift cluster
make deploy-dpf             # Deploy DPF operator
make add-worker-nodes       # Add worker nodes
```

### Management
```bash
make worker-status          # Check worker status
make run-dpf-sanity        # Health checks
make clean-all             # Complete cleanup
```

## 🎯 Supported Versions

- **OpenShift**: 4.20 (only supported version)
- **DPF**: v25.7+ (production), v25.4+ (legacy support)
- **Hardware**: NVIDIA BlueField-3 DPUs on Dell/HPE/Supermicro servers

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.

## 💬 Support

- **Issues**: Report problems in [GitHub Issues](https://github.com/rh-ecosystem-edge/openshift-dpf/issues)
- **Documentation**: Complete user guides in [`docs/user-guide/`](docs/user-guide/)
- **Community**: Join discussions in repository discussions

---

**Get started with your first deployment**: [Getting Started Guide](docs/user-guide/getting-started.md)