# Worker Provisioning

Add physical servers as OpenShift worker nodes using automated bare metal provisioning with NVIDIA DPUs.

## Quick Start

### 1. Prerequisites

**Before starting**: Ensure you have a running OpenShift DPF cluster

**Hardware Requirements**:
- Physical servers with BMC/iDRAC access
- NVIDIA BlueField-3 DPUs installed
- Network connectivity from automation host to BMC interfaces

**Verify connectivity**:
```bash
# Test BMC access
ping 192.168.1.101
curl -k https://192.168.1.101/redfish/v1/
```

**Supported BMCs**: Dell iDRAC, HPE iLO, Supermicro (auto-detected)

### 2. Configure Workers

Add to your `.env` file:

```bash
# Number of workers to provision
WORKER_COUNT=2

# Worker 1 (replace with your actual values)
WORKER_1_NAME=worker-01                    # Choose unique hostname
WORKER_1_BMC_IP=192.168.1.101             # Your BMC IP address
WORKER_1_BMC_USER=admin                    # Your BMC username (NOT root/calvin!)
WORKER_1_BMC_PASSWORD=your_secure_password # Your BMC password
WORKER_1_BOOT_MAC=aa:bb:cc:dd:ee:01        # MAC of PXE network interface

# Worker 2 (follow same pattern for additional workers)
WORKER_2_NAME=worker-02
WORKER_2_BMC_IP=192.168.1.102
WORKER_2_BMC_USER=admin
WORKER_2_BMC_PASSWORD=your_secure_password
WORKER_2_BOOT_MAC=aa:bb:cc:dd:ee:02

# Security (recommended for production)
AUTO_APPROVE_WORKER_CSR=false
```

**Finding your boot MAC address:** See [Finding the Boot MAC Address](#finding-the-boot-mac-address) below for detailed instructions.

### 3. Deploy Workers

```bash
# Add workers to existing cluster
make add-worker-nodes

# Monitor progress
make worker-status
```

### 4. Approve Certificates (if manual approval)

```bash
# Check for pending requests
oc get csr | grep Pending

# Approve each worker's certificate
oc adm certificate approve <csr-name>

# Verify nodes joined
oc get nodes
```

**That's it!** Your workers are now part of the OpenShift cluster with DPU acceleration.

## How It Works

The automation uses **automatic hardware detection**:

- **BMC Discovery**: Connects to your BMC IP and auto-detects vendor type (Dell/HPE/Supermicro)
- **Redfish Protocol**: Uses standard API to control server power and boot
- **Network Boot**: Servers PXE boot OpenShift worker image from cluster
- **Auto-Join**: Workers automatically request to join cluster via certificates

No vendor-specific configuration needed - it just works.

## Configuration Reference

### Required Variables (per worker)

| Variable | Description | Example |
|----------|-------------|---------|
| `WORKER_n_NAME` | Unique hostname (n = worker number) | `worker-01` |
| `WORKER_n_BMC_IP` | BMC management IP address | `192.168.1.101` |
| `WORKER_n_BMC_USER` | BMC username (use secure credentials) | `admin` |
| `WORKER_n_BMC_PASSWORD` | BMC password | `your_password` |
| `WORKER_n_BOOT_MAC` | PXE network interface MAC address | `aa:bb:cc:dd:ee:01` |

### Optional Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WORKER_n_ROOT_DEVICE` | Installation disk | `/dev/sda` |
| `AUTO_APPROVE_WORKER_CSR` | Automatic certificate approval | `false` |
| `CSR_APPROVAL_TIMEOUT` | Manual approval timeout | `600` (10min) |

### Security Settings

```bash
# Production (recommended)
AUTO_APPROVE_WORKER_CSR=false   # Manual approval required

# Lab/Development (less secure)
AUTO_APPROVE_WORKER_CSR=true    # Automatic approval
```

## Monitoring

### Check Worker Status

```bash
# Overall status
make worker-status

# Detailed BMC status
oc get bmh -n openshift-machine-api

# Node status
oc get nodes

# Certificate requests
oc get csr
```

### Expected Progression

1. **BMC Registration**: `registering → available`
2. **Provisioning**: `available → provisioning → provisioned`
3. **Node Joining**: `NotReady → Ready` (after CSR approval)

## Common Issues

### BMC Not Reachable

```bash
# Test connectivity
ping 192.168.1.101
curl -k https://192.168.1.101/redfish/v1/

# Check credentials (use your actual BMC credentials)
curl -k -u admin:your_password https://192.168.1.101/redfish/v1/
```

### Worker Stuck in "Registering"

```bash
# Check BMO operator logs
oc logs -n openshift-machine-api deployment/metal3

# Common causes: wrong credentials, network issues, BMC in maintenance mode
```

### No Certificate Requests Appearing

```bash
# Check if worker booted successfully via BMC console
# Verify network connectivity from worker subnet to cluster API
ping <API_VIP>
```

### Node Stuck in "NotReady"

```bash
# Check node conditions
oc describe node worker-01

# Usually resolves after CSR approval and brief initialization
```

## Finding the Boot MAC Address

The `WORKER_n_BOOT_MAC` is the MAC address of the network interface used for PXE booting. You need the NIC that is connected to your cluster network.

### Method 1: Redfish API (Recommended)

Query your BMC directly to list all NICs and their status. Use the interface with `LinkUp` status.

**Dell iDRAC Example:**

```bash
# Set your BMC details
BMC_IP=192.168.1.101
BMC_USER=admin
BMC_PASSWORD=your_password

# List all NICs with MAC address and link status
curl -sk -u ${BMC_USER}:${BMC_PASSWORD} \
  https://${BMC_IP}/redfish/v1/Systems/System.Embedded.1/EthernetInterfaces \
  | jq -r '.Members[]."@odata.id"' \
  | while read nic; do
      curl -sk -u ${BMC_USER}:${BMC_PASSWORD} "https://${BMC_IP}${nic}" \
        | jq -r '"\(.Id): \(.MACAddress) (\(.LinkStatus // "Unknown"))"'
    done
```

**Example output:**

```
NIC.Integrated.1-1-1: 30:3E:A7:13:EB:70 (LinkUp)
NIC.Embedded.1-1-1: C4:CB:E1:C4:7E:30 (LinkDown)
NIC.Embedded.2-1-1: C4:CB:E1:C4:7E:31 (LinkDown)
NIC.Slot.1-1: B8:CE:F6:04:9A:E0 (LinkDown)
```

In this example, use `30:3E:A7:13:EB:70` since it's the only NIC with `LinkUp`.

**HPE iLO Example:**

```bash
# HPE uses a different system path
curl -sk -u ${BMC_USER}:${BMC_PASSWORD} \
  https://${BMC_IP}/redfish/v1/Systems/1/EthernetInterfaces \
  | jq -r '.Members[]."@odata.id"' \
  | while read nic; do
      curl -sk -u ${BMC_USER}:${BMC_PASSWORD} "https://${BMC_IP}${nic}" \
        | jq -r '"\(.Id): \(.MACAddress) (\(.LinkStatus // "Unknown"))"'
    done
```

**Supermicro Example:**

```bash
# Supermicro typically uses System/1 path
curl -sk -u ${BMC_USER}:${BMC_PASSWORD} \
  https://${BMC_IP}/redfish/v1/Systems/1/EthernetInterfaces \
  | jq -r '.Members[]."@odata.id"' \
  | while read nic; do
      curl -sk -u ${BMC_USER}:${BMC_PASSWORD} "https://${BMC_IP}${nic}" \
        | jq -r '"\(.Id): \(.MACAddress) (\(.LinkStatus // "Unknown"))"'
    done
```

> **Tip**: If you're unsure of the system path, first query the systems endpoint to discover it:
> ```bash
> curl -sk -u ${BMC_USER}:${BMC_PASSWORD} https://${BMC_IP}/redfish/v1/Systems/ | jq '.Members'
> ```
> This returns the correct system ID for your hardware (e.g., `System.Embedded.1` for Dell, `1` for HPE/Supermicro).

> **Note**: The Redfish API also provides `PermanentMACAddress` which is the burned-in hardware MAC. This is typically the same as `MACAddress` unless the MAC has been overridden.

### Method 2: BMC Web Interface

1. Log into your BMC web interface (e.g., `https://192.168.1.101`)
2. Navigate to:
   - **Dell iDRAC**: System → Network → Network Interfaces
   - **HPE iLO**: Information → Network → Physical Network Adapters
   - **Supermicro**: System Information → Network
3. Find the NIC connected to your cluster network
4. Copy the MAC address

### Method 3: From Existing OS

If the server currently has an OS installed:

```bash
# SSH to the server
ssh root@server-ip

# List all interfaces with MAC addresses
ip link show

# Or get just MAC addresses
cat /sys/class/net/*/address
```

### Which NIC to Choose?

Select the NIC that:
- Shows **LinkUp** status (connected to network)
- Is connected to the **same network** as your OpenShift cluster nodes
- Will be used for **PXE/network boot** (usually the first onboard NIC)
- Is **NOT** the BMC/iDRAC dedicated management interface

## Advanced Topics

### Adding More Workers

```bash
# Update worker count
echo "WORKER_COUNT=3" >> .env

# Add new worker variables
echo "WORKER_3_NAME=worker-03" >> .env
echo "WORKER_3_BMC_IP=192.168.1.103" >> .env
echo "WORKER_3_BMC_USER=root" >> .env
echo "WORKER_3_BMC_PASSWORD=calvin" >> .env
echo "WORKER_3_BOOT_MAC=aa:bb:cc:dd:ee:03" >> .env

# Deploy new worker
make add-worker-nodes
```

### BMC Security Checklist

- Change default credentials immediately
- Use dedicated management network/VLAN
- Enable audit logging where available
- Restrict BMC network access

### Automatic CSR Approval

**⚠️ Security Warning**: Only enable in trusted lab environments.

```bash
AUTO_APPROVE_WORKER_CSR=true
CSR_APPROVAL_TIMEOUT=300  # 5 minutes
```

With automatic approval, workers join the cluster without manual intervention.

## Next Steps

- **Complete Deployment**: See [Getting Started](getting-started.md) for full cluster setup
- **DPU Services**: Configure accelerated networking with DPU features
- **Troubleshooting**: See [Troubleshooting Guide](troubleshooting.md) for additional issues

Your workers are now ready for DPU-accelerated workloads on OpenShift.