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

## Environment Configuration (`.env` Generation)

All scripts and Make targets read configuration from a single `.env` file at the
repo root. This file is generated — never edit the source files in `ci/`
for your local setup.

### Source files (in `ci/`)

| File | Role |
|------|------|
| `ci/env.defaults` | Default values for every optional variable. User environment variables always overwrite these. |
| `ci/env.required` | Variables that have no default and must be provided. Generation fails immediately if these are not set in user environment. |
| `ci/env.template` | The canonical set variables used by the scripts `.env` and in what order.|

### How to generate

1. **Export your required variables** (and any optional overrides):

   ```bash
   export CLUSTER_NAME=my-cluster
   export BASE_DOMAIN=example.com
   export API_VIP=10.1.150.100
   export INGRESS_VIP=10.1.150.101
   export DPU_HOST_CIDR=10.0.110.0/24
   export BFB_URL=https://content.mellanox.com/BlueField/...
   ```

   To keep overrides reusable, put them in a personal file (e.g. `user.env`)
   and source it first:

   ```bash
   source user.env
   make generate-env  
   ```

2. **Run the generator:**

   ```bash
   make generate-env                # creates .env (fails if .env already exists)
   make generate-env FORCE=true     # overwrites an existing .env
   ```

### What happens under the hood

1. `ci/env.defaults` is sourced — sets defaults for every variable, but
   does not overwrite anything already exported in your shell.
2. `ci/env.required` is sourced — aborts with an error if any required
   variable is still unset.
3. `envsubst` renders `ci/env.template` into `.env`, substituting every
   `${VAR}` with its resolved value.

### Result

A flat `KEY=VALUE` file at the repo root (`.env`) containing the merged
result of your overrides + the defaults. This is consumed by `make` and `scripts/env.sh` at runtime.

### Validation

```bash
make validate-env-files
```

Checks that every variable in `ci/env.defaults` has a corresponding entry in
`ci/env.template` so nothing is silently dropped, and report template-only variables that have no default.

## 📖 Documentation

| Guide | Purpose |
|-------|---------|
| **[Getting Started](docs/user-guide/getting-started.md)** | Step-by-step setup guide |
| **[Configuration](docs/user-guide/configuration.md)** | Environment variables |
| **[Worker Provisioning](docs/user-guide/worker-provisioning.md)** | Add physical worker nodes |
| **[Troubleshooting](docs/user-guide/troubleshooting.md)** | Fix common issues |
| **[External storage](docs/user-guide/external-storage-requirements.md)** | SKIP_DEPLOY_STORAGE and storage requirements |

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

### Workers with static IPs
To assign fixed IPs to worker nodes, set `WORKER_STATIC_IP=true` and configure per-worker variables. See [Worker Provisioning – Workers with static IPs](docs/user-guide/worker-provisioning.md#workers-with-static-ips).

### VMs with static IPs
To assign fixed IPs to cluster VMs (e.g. for predictable addressing or firewall rules), set `VM_STATIC_IP=true` and provide these **required** variables in `.env`:

| Variable     | Description |
|-------------|----------------------------------------------------------------|
| `VM_EXT_IPS` | Comma-separated list of static IPs, **one per VM** (must have at least `VM_COUNT` entries). Example: `10.8.2.110,10.8.2.111,10.8.2.112` |
| `VM_EXT_PL`  | Prefix length for the subnet (e.g. `24` for /24) |
| `VM_GW`      | Default gateway IP |
| `VM_DNS`     | DNS server IP(s), comma-separated |

Example for 3 VMs:
```bash
VM_STATIC_IP=true
VM_EXT_IPS=10.8.2.110,10.8.2.111,10.8.2.112
VM_EXT_PL=24
VM_GW=10.8.2.1
VM_DNS=8.8.8.8,4.4.4.4
```

Optional: `PRIMARY_IFACE` (default `enp1s0`) — interface name used for static config on the VMs.

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
