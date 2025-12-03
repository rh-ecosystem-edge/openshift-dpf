# Getting Started with OpenShift DPF Automation

This guide walks you through setting up and running your first OpenShift DPF deployment. Follow these steps in order for a successful deployment.

## Step 1: Verify Prerequisites

### Host Requirements

Your host system needs:

- **Operating System**: RHEL 8/9, CentOS Stream 8/9, or compatible Linux
- **RAM**: Minimum 32GB (64GB+ recommended for multi-node)
- **CPU**: 8+ cores (16+ cores recommended)
- **Storage**: 200GB+ free disk space
- **Network**: Reliable internet connection for image downloads

### Check System Resources

```bash
# Check available RAM (need 32GB minimum)
free -h

# Check available disk space (need 200GB minimum)
df -h /

# Check CPU cores (need 8+ cores)
nproc

# Verify virtualization support (if using VMs)
grep -E 'vmx|svm' /proc/cpuinfo
```

## Step 2: Install Required Tools

The automation requires several CLI tools. Some can be installed automatically, others need manual installation.

### Automatic Tool Installation

```bash
# Clone the repository
git clone <repository-url>
cd openshift-dpf

# Install Helm and Hypershift automatically
make install-helm
make install-hypershift
```

### Manual Tool Installation

#### Red Hat Assisted Installer CLI (aicli)

```bash
# Install from Red Hat
# Visit: https://console.redhat.com/openshift/install/pull-secret
# Download and follow aicli installation instructions

# Verify installation
aicli --version
```

#### OpenShift CLI (oc)

```bash
# Download from Red Hat
curl -O https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar xzf openshift-client-linux.tar.gz
sudo mv oc kubectl /usr/local/bin/

# Verify installation
oc version --client
```

#### Other Required Tools

```bash
# Install system packages (RHEL/CentOS)
sudo dnf install -y jq libvirt-client podman

# For Ubuntu/Debian
sudo apt install -y jq virtinst podman
```

## Step 3: Obtain Required Credentials

### Red Hat Pull Secret

1. Visit [Red Hat OpenShift Downloads](https://console.redhat.com/openshift/install/pull-secret)
2. Log in with your Red Hat account
3. Download the pull secret
4. Save as `openshift_pull.json` in the project directory

### Red Hat Offline Token

1. Visit [Red Hat API Tokens](https://cloud.redhat.com/openshift/token)
2. Copy your offline token
3. Create the aicli config directory and save the token:

```bash
mkdir -p ~/.aicli
echo "YOUR_OFFLINE_TOKEN" > ~/.aicli/offlinetoken.txt
chmod 600 ~/.aicli/offlinetoken.txt
```

### NVIDIA NGC API Key

1. Create account at [NVIDIA NGC](https://ngc.nvidia.com/)
2. Go to Account → Setup → Generate API Key
3. Create NGC pull secret:

```bash
cat > pull-secret.txt << 'EOF'
{
  "auths": {
    "nvcr.io": {
      "username": "$oauthtoken",
      "password": "YOUR_NGC_API_KEY",
      "auth": "BASE64_ENCODED_TOKEN_PAIR"
    }
  }
}
EOF
```

**Note**: Replace `YOUR_NGC_API_KEY` with your actual API key and generate the base64 auth string.

### SSH Key

Generate an SSH key for cluster access:

```bash
# Generate new SSH key (if you don't have one)
ssh-keygen -t rsa -f ~/.ssh/id_rsa -N ""

# Verify public key exists
ls -la ~/.ssh/id_rsa.pub
```

## Step 4: Configure Environment

### Copy Configuration Template

```bash
# Copy the example configuration
cp .env.example .env
```

### Basic Configuration

Edit `.env` and set these essential variables:

```bash
# Cluster Configuration
CLUSTER_NAME=my-dpf-cluster
BASE_DOMAIN=example.com
OPENSHIFT_VERSION=4.20.0

# VM Configuration (adjust based on your resources)
VM_COUNT=3                    # 1 for SNO, 3+ for multi-node
RAM=16384                     # RAM per VM in MB
VCPUS=8                       # vCPUs per VM
DISK_SIZE1=120               # Primary disk in GB
DISK_SIZE2=80                # Secondary disk in GB

# DPF Configuration
DPF_VERSION=v25.7.1          # Use latest stable version
```

### Network Configuration (Multi-Node Only)

For multi-node clusters, you need VIP addresses:

```bash
# Network Configuration (required for multi-node)
API_VIP=10.1.150.100         # API server VIP
INGRESS_VIP=10.1.150.101     # Ingress VIP
```

**Important**: VIP addresses must be:
- In the same network as your host
- Not currently assigned to any device
- Accessible from your host system

## Step 5: Verify Setup

Before deploying, verify your setup:

```bash
# Check all required files exist
make verify-files

# This should show:
# ✓ openshift_pull.json exists
# ✓ pull-secret.txt exists
# ✓ SSH public key exists
# ✓ .env configuration exists
```

## Step 6: Run Your First Deployment

### Single-Node OpenShift (Recommended for First-Time)

```bash
# Configure for SNO
echo "VM_COUNT=1" >> .env

# Deploy everything
make all

# This will take about 2 hours and includes:
# - Creating cluster definition
# - Creating and starting VMs
# - Installing OpenShift
# - Deploying DPF operator
# - Setting up DPU services
```

### Monitor Deployment Progress

Open a new terminal and monitor progress:

```bash
# Watch cluster installation status
watch 'aicli list clusters'

# Monitor VM status
watch 'virsh list --all'

# Check OpenShift nodes (after cluster is ready)
watch 'oc get nodes'

# Monitor DPF operator deployment
watch 'oc get pods -n dpf-operator-system'
```

## Step 7: Verify Successful Deployment

After deployment completes, verify everything is working:

```bash
# Check cluster nodes
oc get nodes

# Check DPF operator
oc get pods -n dpf-operator-system

# Check hosted cluster (for DPU workloads)
oc get hostedcluster -n clusters

# Run comprehensive health check
make run-dpf-sanity
```

Expected output for a successful deployment:
```
NAME                STATUS   ROLES           AGE   VERSION
vm-dpf-0            Ready    control-plane   45m   v1.29.0+xxx
vm-dpf-1            Ready    control-plane   45m   v1.29.0+xxx
vm-dpf-2            Ready    control-plane   45m   v1.29.0+xxx
```

## Common First-Time Issues

### Issue: Pull Secret Errors
**Symptom**: Errors downloading container images
**Solution**: Verify both `openshift_pull.json` and `pull-secret.txt` are valid JSON

### Issue: VM Creation Fails
**Symptom**: "Cannot create VM" errors
**Solution**: Ensure libvirt is running and you have sufficient resources

```bash
sudo systemctl start libvirtd
sudo systemctl enable libvirtd
sudo usermod -a -G libvirt $USER
# Log out and back in for group changes
```

### Issue: Network Connectivity
**Symptom**: VMs cannot reach the internet
**Solution**: Check your default network bridge

```bash
# Check libvirt network
virsh net-list
virsh net-start default  # if not running
```

### Issue: Insufficient Resources
**Symptom**: VMs run slowly or fail to start
**Solution**: Reduce resource allocation in `.env`

```bash
# For resource-constrained systems
VM_COUNT=1               # Use SNO
RAM=8192                # 8GB per VM
VCPUS=4                 # 4 vCPUs per VM
```

## Next Steps

Once your first deployment is successful:

1. **Learn about configuration**: Read [Configuration Guide](configuration.md)
2. **Add worker nodes**: See [Worker Provisioning](worker-provisioning.md)
3. **Deploy workloads**: Your cluster is ready for applications
4. **Explore advanced features**: Check [Advanced Topics](advanced-topics.md)

## Getting Help

- **Troubleshooting**: See [Troubleshooting Guide](troubleshooting.md)
- **Issues**: Report problems in the repository
- **Documentation**: This user guide covers common scenarios

---

**Congratulations!** You now have a working OpenShift cluster with NVIDIA DPF automation. The cluster is ready to run DPU-accelerated workloads.