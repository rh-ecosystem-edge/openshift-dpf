# Worker Provisioning with BMO

This guide explains how to add worker nodes with NVIDIA DPUs to your OpenShift DPF cluster using automated Bare Metal Operator (BMO) provisioning.

## Overview

Worker provisioning automates the deployment of physical servers as OpenShift worker nodes through:

- **Bare Metal Operator (BMO)** for hardware lifecycle management
- **Redfish protocol** for BMC communication and control
- **Automated CSR approval** for seamless node joining
- **DPU integration** for accelerated networking

## Prerequisites

### Hardware Requirements

- **Physical servers** with BMC/iDRAC access
- **NVIDIA BlueField-3 DPUs** installed and configured
- **Network connectivity** from automation host to BMC interfaces
- **PXE boot capability** or virtual media support

### Network Requirements

```bash
# BMC network access (test before provisioning)
ping 192.168.1.101           # BMC must be reachable
curl -k https://192.168.1.101/redfish/v1/   # Redfish API accessible

# Boot network configuration
# Workers need network access to cluster for image download
# Ensure DHCP or static network configuration available
```

### Supported Hardware

| Vendor | BMC Type | Status | Auto-Discovery |
|--------|----------|--------|----------------|
| **Dell** | iDRAC 9+ | ✅ Tested | ✅ Automatic |
| **HPE** | iLO 5+ | ✅ Compatible | ✅ Automatic |
| **Supermicro** | BMC | ✅ Compatible | ✅ Automatic |

**Auto-Discovery Support**: All hardware uses automatic Redfish endpoint discovery. No manual system path configuration required - ironic automatically detects the correct vendor-specific endpoints.

## Configuration

### Basic Worker Configuration

Add worker configuration to your `.env` file:

```bash
# Worker Provisioning Settings
WORKER_COUNT=2                      # Number of workers to provision
AUTO_APPROVE_WORKER_CSR=false       # Manual CSR approval (recommended)
CSR_APPROVAL_TIMEOUT=600            # CSR approval timeout (seconds)
```

### Per-Worker Configuration

Configure each worker with specific hardware details:

```bash
# Worker 1 Configuration
WORKER_1_NAME=openshift-worker-1           # Unique worker name
WORKER_1_BMC_IP=192.168.1.101             # BMC IP address
WORKER_1_BMC_USER=root                     # BMC username
WORKER_1_BMC_PASSWORD=calvin               # BMC password
WORKER_1_BOOT_MAC=aa:bb:cc:dd:ee:01        # PXE boot NIC MAC
WORKER_1_ROOT_DEVICE=/dev/sda              # Installation disk

# Worker 2 Configuration
WORKER_2_NAME=openshift-worker-2
WORKER_2_BMC_IP=192.168.1.102
WORKER_2_BMC_USER=root
WORKER_2_BMC_PASSWORD=calvin
WORKER_2_BOOT_MAC=aa:bb:cc:dd:ee:02
WORKER_2_ROOT_DEVICE=/dev/sda

# Additional workers follow same pattern...
# WORKER_3_NAME=openshift-worker-3
# ...continue for each worker up to WORKER_COUNT
```

### Security Configuration

```bash
# Production Security Settings
AUTO_APPROVE_WORKER_CSR=false       # Manual approval required
CSR_APPROVAL_TIMEOUT=600            # 10 minutes for manual approval

# Development/Lab Settings (less secure)
AUTO_APPROVE_WORKER_CSR=true        # Automatic CSR approval
CSR_APPROVAL_TIMEOUT=300            # 5 minutes timeout
```

### DPU Configuration

Configure DPU settings for accelerated networking:

```bash
# DPU Interface Configuration
DPU_INTERFACE=ens7f0np0             # Physical DPU interface name
DPU_OVN_VF=ens7f0v1                # OVN virtual function interface
NUM_VFS=46                          # Number of SR-IOV virtual functions

# DPU Network Configuration
DPU_HOST_CIDR=10.6.130.0/24         # DPU host network range
HBN_OVN_NETWORK=10.6.150.0/27       # HBN OVN IPAM range

# SR-IOV Configuration
INJECTOR_RESOURCE_NAME=openshift.io/bf3-p0-vfs    # SR-IOV resource name
```

## Redfish Auto-Discovery

The worker provisioning system uses **automatic Redfish endpoint discovery** for maximum compatibility across hardware vendors.

### How Auto-Discovery Works

1. **BMC Connection**: Ironic connects to the BMC at `https://<BMC_IP>`
2. **Service Discovery**: Queries the Redfish service root (`/redfish/v1/`)
3. **Endpoint Detection**: Follows standard Redfish links to discover the Systems endpoint
4. **Vendor Agnostic**: Works with any Redfish-compliant BMC without vendor-specific configuration

### Vendor-Specific Paths (Auto-Discovered)

| Vendor | Auto-Discovered Path |
|--------|---------------------|
| **Dell iDRAC** | `/redfish/v1/Systems/System.Embedded.1` |
| **HPE iLO** | `/redfish/v1/Systems/1` |
| **Supermicro** | `/redfish/v1/Systems/1` |

**Note**: These paths are automatically discovered - you don't need to specify them in configuration.

### Benefits of Auto-Discovery

- **Multi-Vendor Support**: Works with Dell, HPE, Supermicro without configuration changes
- **Simplified Configuration**: No vendor-specific system paths needed in `.env` files
- **Future-Proof**: Supports new BMC vendors that implement standard Redfish
- **Reduced Maintenance**: No vendor-specific logic to maintain in automation

## Deployment Process

### Full Automated Deployment

Deploy cluster and workers in one command:

```bash
# Complete deployment including workers
make all

# This executes:
# 1. Cluster creation and installation
# 2. DPF operator deployment
# 3. DPU services configuration
# 4. Worker node provisioning
# 5. CSR approval (if AUTO_APPROVE_WORKER_CSR=true)
```

### Step-by-Step Deployment

For more control, deploy in phases:

```bash
# 1. Deploy control plane first
make create-cluster create-vms cluster-install

# 2. Deploy DPF operator and services
make deploy-dpf deploy-dpu-services

# 3. Add worker nodes
make add-worker-nodes

# 4. Monitor and approve CSRs (if manual approval)
make worker-status
oc get csr | grep Pending
oc adm certificate approve <csr-name>
```

### Manual CSR Approval Process

If `AUTO_APPROVE_WORKER_CSR=false`, you'll need to manually approve certificates:

```bash
# 1. Start worker provisioning
make add-worker-nodes

# 2. Monitor provisioning progress
watch 'oc get bmh -n openshift-machine-api'

# 3. Wait for pending CSRs (appears when worker boots)
watch 'oc get csr'

# 4. Approve worker CSRs
oc get csr | grep Pending
oc adm certificate approve <csr-name>

# 5. Verify nodes join cluster
watch 'oc get nodes'
```

## Monitoring and Status

### Worker Provisioning Status

```bash
# Check BareMetalHost status
oc get bmh -n openshift-machine-api

# Expected progression:
# 1. registering -> 2. inspecting -> 3. available -> 4. provisioning -> 5. provisioned

# Detailed status for specific worker
oc describe bmh -n openshift-machine-api openshift-worker-1
```

### Node Status

```bash
# Monitor node joining process
oc get nodes

# Expected progression:
# 1. Node appears in NotReady state
# 2. CSR appears and gets approved
# 3. Node transitions to Ready state

# Check node details
oc describe node openshift-worker-1
```

### CSR Status

```bash
# List all CSRs
oc get csr

# Filter pending CSRs
oc get csr | grep Pending

# Get CSR details
oc describe csr <csr-name>
```

### Automated Status Commands

```bash
# Comprehensive worker status
make worker-status

# This shows:
# - BareMetalHost status
# - Node status
# - Pending CSRs
# - DPU interface status
```

## BMC Configuration

### Dell iDRAC 9 Configuration

```bash
# Verify iDRAC access
curl -k -u root:calvin https://192.168.1.101/redfish/v1/

# Common iDRAC settings for automation
# 1. Enable Redfish API
# 2. Configure virtual media
# 3. Set boot order (PXE first)
# 4. Enable IPMI over LAN
```

### Redfish Auto-Discovery Testing

```bash
# Test Redfish service root (auto-discovery starting point)
curl -k https://${BMC_IP}/redfish/v1/

# Expected response: JSON with service information and Systems link

# Test authentication (ironic will use this)
curl -k -u ${BMC_USER}:${BMC_PASSWORD} \
  https://${BMC_IP}/redfish/v1/

# Expected: Authenticated access to service root

# Auto-discovery will automatically find the correct Systems endpoint
# No need to manually specify vendor-specific paths
```

### BMC Security Considerations

```bash
# Production BMC Setup Checklist
# 1. Change default credentials (never use calvin/calvin)
# 2. Configure dedicated management VLAN
# 3. Restrict BMC network access
# 4. Enable BMC audit logging
# 5. Configure LDAP/AD authentication if available
```

## Troubleshooting

### BMC Connectivity Issues

**Problem: Cannot reach BMC**
```bash
# Check network connectivity
ping 192.168.1.101
telnet 192.168.1.101 443

# Verify Redfish API
curl -k https://192.168.1.101/redfish/v1/

# Check credentials
curl -k -u root:calvin https://192.168.1.101/redfish/v1/
```

**Problem: Authentication failures**
```bash
# Verify BMC credentials with service root (auto-discovery starting point)
curl -k -u ${BMC_USER}:${BMC_PASSWORD} \
  https://${BMC_IP}/redfish/v1/

# Common credential issues:
# - Default passwords changed
# - Account locked due to failed attempts
# - LDAP authentication required
# - BMC in maintenance mode

# Note: Auto-discovery will handle vendor-specific endpoints automatically
```

### Provisioning Issues

**Problem: BareMetalHost stuck in 'registering' state**
```bash
# Check BMO operator logs
oc logs -n openshift-machine-api deployment/metal3

# Check for common issues:
# - BMC credential failures
# - Network connectivity
# - Redfish API incompatibility
```

**Problem: Worker not booting from PXE**
```bash
# Verify boot MAC address
# - Must match actual PXE interface
# - Check cable connections
# - Verify switch port configuration

# Check iDRAC virtual console for boot process
# - Access via BMC web interface
# - Monitor boot sequence
# - Verify DHCP assignment
```

**Problem: CSR not appearing**
```bash
# Check worker console/iDRAC for boot errors
# Common issues:
# - Network configuration problems
# - Image download failures
# - Hardware initialization errors

# Verify cluster accessibility from worker network
# Test from worker subnet:
ping ${API_VIP}
curl -k https://${API_VIP}:6443/healthz
```

### Node Join Issues

**Problem: Node stuck in NotReady state**
```bash
# Check node conditions
oc describe node openshift-worker-1

# Common issues:
# - Container runtime not ready
# - Network plugin not configured
# - Resource constraints
```

**Problem: CSR approval fails**
```bash
# Check CSR details
oc describe csr <csr-name>

# Manual approval with debugging
oc adm certificate approve <csr-name> -v=4

# Verify cluster CA trust
oc get cm -n kube-system cluster-ca
```

### DPU Configuration Issues

**Problem: DPU interfaces not configured**
```bash
# Check SR-IOV operator
oc get pods -n openshift-sriov-network-operator

# Verify SR-IOV policy
oc get sriovnetworkpolicy -n openshift-sriov-network-operator

# Check DPU interface status on worker
oc debug node/openshift-worker-1
chroot /host
ip link show | grep ${DPU_INTERFACE}
```

### Advanced Diagnostics

```bash
# BMO webhook logs
oc logs -n openshift-machine-api \
  $(oc get pods -n openshift-machine-api -l app=metal3-admission-webhook -o name)

# Ironic logs (bare metal provisioning)
oc logs -n openshift-machine-api \
  $(oc get pods -n openshift-machine-api -l app=metal3-ironic -o name)

# Machine API operator logs
oc logs -n openshift-machine-api \
  $(oc get pods -n openshift-machine-api -l k8s-app=machine-api-operator -o name)
```

## Security Considerations

### CSR Auto-Approval Security

```bash
# WARNING: Auto-approval bypasses certificate verification
# Only use AUTO_APPROVE_WORKER_CSR=true in trusted environments

# Production recommendation:
AUTO_APPROVE_WORKER_CSR=false

# Manual approval process:
# 1. Verify CSR details before approval
# 2. Check worker hardware identity
# 3. Confirm expected deployment timing
# 4. Approve only expected CSRs
```

### BMC Security Best Practices

```bash
# 1. Use dedicated management network
# - Isolate BMC traffic from production
# - Configure VLANs for BMC access
# - Restrict routing between networks

# 2. Strong authentication
# - Change default credentials immediately
# - Use complex passwords
# - Enable account lockout policies
# - Configure LDAP/AD if available

# 3. Access control
# - Limit BMC network access
# - Use VPN for remote access
# - Monitor BMC access logs
# - Regular credential rotation
```

### Network Security

```bash
# 1. PXE boot security
# - Use secure boot where possible
# - Verify image signatures
# - Monitor DHCP for unauthorized requests

# 2. Cluster communication
# - Ensure TLS for all cluster communication
# - Verify certificate chains
# - Monitor for certificate anomalies
```

## Advanced Configuration

### Custom Boot Configuration

```bash
# Custom root device hints
WORKER_1_ROOT_DEVICE=/dev/disk/by-path/pci-0000:00:1f.2-ata-1

# Multiple disk configuration
WORKER_1_ROOT_DEVICE_NAME=sda
WORKER_1_ROOT_DEVICE_SIZE=480    # GB
```

### Custom Network Configuration

```bash
# Static network configuration for workers
# Create custom NetworkManager configuration
# Apply via user-data Secret modification
```

### Scaling Operations

```bash
# Add additional workers after initial deployment
# 1. Update WORKER_COUNT in .env
# 2. Add new WORKER_N_* variables
# 3. Run: make add-worker-nodes

# Example: Adding worker 3
echo "WORKER_COUNT=3" >> .env
echo "WORKER_3_NAME=openshift-worker-3" >> .env
echo "WORKER_3_BMC_IP=192.168.1.103" >> .env
# ... add remaining WORKER_3_* variables

make add-worker-nodes
```

## Next Steps

- **Deployment**: Follow [Deployment Scenarios](deployment-scenarios.md) for complete deployment
- **Configuration**: See [Configuration Guide](configuration.md) for detailed settings
- **Troubleshooting**: Refer to [Troubleshooting Guide](troubleshooting.md) for issue resolution
- **Getting Started**: New to the automation? Start with [Getting Started](getting-started.md)

Worker provisioning completes your OpenShift DPF deployment with automated hardware lifecycle management and DPU acceleration capabilities.