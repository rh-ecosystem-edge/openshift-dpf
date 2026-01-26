# Advanced Topics

Advanced configuration options and optimization techniques for OpenShift DPF deployments.

## Performance Optimization

### Host System Performance

```bash
# Enable performance governor for better CPU performance
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Configure hugepages (optional, for high-memory workloads)
echo 1024 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Disable swap for consistent performance
sudo swapoff -a
```

### Network Performance

```bash
# Enable jumbo frames (requires compatible network infrastructure)
NODES_MTU=9000  # Add to .env file

# This configures:
# - VM network interfaces with 9000 MTU
# - Cluster networking with jumbo frame support
# - DPU interfaces optimized for high throughput
```

### DPU Optimization

```bash
# Optimize SR-IOV VF allocation for your workload
NUM_VFS=32                    # Reduce if not using all VFs
DPU_INTERFACE=ens7f0np0      # Verify correct DPU interface
DPU_OVN_VF=ens7f0v1          # First VF for OVN-Kubernetes

# Advanced DPU network configuration
HBN_OVN_NETWORK=10.6.150.0/27    # HBN network range
DPU_HOST_CIDR=10.6.130.0/24      # DPU host communication
```

## Custom Configuration

### Single-Node OpenShift (SNO) Optimization

```bash
# SNO-specific settings
CLUSTER_TYPE=SNO
VM_COUNT=1                    # Single VM for SNO
RAM=48172                     # Minimum RAM for SNO + DPF
VCPUS=16                      # Minimum CPUs for SNO + DPF

# Storage optimization for SNO
ISO_TYPE=minimal              # Use minimal ISO for faster boot
```

### Multi-Node Production Settings

```bash
# Production cluster sizing
VM_COUNT=5                    # 3 control plane + 2 initial workers
RAM=65536                     # More RAM per node for production
VCPUS=16                      # More CPU for production workloads

# Production storage
# Uses ODF (OpenShift Data Foundation) automatically
```

### Custom Network Configuration

```bash
# Advanced network settings
API_VIP=10.1.150.100         # Cluster API virtual IP
INGRESS_VIP=10.1.150.101     # Ingress virtual IP
POD_CIDR=10.128.0.0/14       # Pod network range
SERVICE_CIDR=172.30.0.0/16   # Service network range

# Bridge network customization
BRIDGE_NAME=br-dpf           # Custom bridge name
NETWORK_NAME=dpf-net         # Libvirt network name
```

## Hypershift Management

### Multiple Hosted Clusters

```bash
# Deploy additional hosted clusters
HOSTED_CLUSTER_NAME=doca-prod     # Different cluster name
CLUSTERS_NAMESPACE=clusters       # Shared namespace
HOSTED_CONTROL_PLANE_NAMESPACE=clusters-doca-prod

# Deploy second cluster
make deploy-hypershift
```

### Hosted Cluster Scaling

```bash
# Scale hosted cluster nodes
oc scale nodepool worker --replicas=5 -n clusters

# Add different node types
oc apply -f - <<EOF
apiVersion: hypershift.openshift.io/v1alpha1
kind: NodePool
metadata:
  name: compute-nodes
  namespace: clusters
spec:
  clusterName: doca
  replicas: 3
  template:
    spec:
      platform:
        type: Agent
EOF
```

## Custom Deployment Scenarios

### Development Environment

```bash
# Minimal resource development setup
VM_COUNT=1
RAM=32768                     # Minimum for development
VCPUS=8
AUTO_APPROVE_WORKER_CSR=true  # Skip manual approval in dev

# Fast deployment options
ISO_TYPE=minimal
SKIP_DPU_SERVICES=true        # Skip DPU services for faster testing
```

### Edge Computing Setup

```bash
# Edge deployment optimization
CLUSTER_TYPE=SNO              # Single node for edge
VM_COUNT=1
RAM=32768                     # Edge resource constraints

# Edge-specific DPF settings
DPF_VERSION=v25.4             # Stable version for edge
WORKER_COUNT=0                # No additional workers for edge
```

### High-Performance Computing (HPC)

```bash
# HPC cluster configuration
VM_COUNT=7                    # 3 control + 4 compute nodes
RAM=131072                    # High memory for HPC workloads
VCPUS=32                      # Maximum CPU for compute

# HPC DPU optimization
NUM_VFS=64                    # Maximum VFs for HPC networking
NODES_MTU=9000               # Jumbo frames for HPC traffic
DPU_INTERFACE=ens7f0np0      # High-speed DPU interface
```

## Integration and Automation

### CI/CD Integration

```bash
# Environment validation for CI/CD
make validate-environment

# Automated cluster deployment
make clean-all create-cluster create-vms cluster-install

# Automated testing
make run-dpf-sanity

# Cleanup for next run
make delete-cluster delete-vms clean-all
```

### External Storage Integration

```bash
# Use external storage instead of local
EXTERNAL_STORAGE=true
STORAGE_CLASS=fast-ssd        # Your storage class name

# Skip local storage operators
SKIP_LSO=true
SKIP_ODF=true
```

### Custom Registry Configuration

```bash
# Use private registry for images
PRIVATE_REGISTRY=registry.example.com
DPF_OPERATOR_IMAGE=${PRIVATE_REGISTRY}/dpf-operator:v25.4

# Registry authentication (add to pull secrets)
# Update openshift_pull.json and pull-secret.txt with your registry credentials
```

## Security Hardening

### Production Security

```bash
# Disable auto-approvals in production
AUTO_APPROVE_WORKER_CSR=false
AUTO_APPROVE_DPUCLUSTER_CSR=false

# Use secure BMC credentials (never use defaults)
WORKER_1_BMC_USER=admin       # Change from root
WORKER_1_BMC_PASSWORD=complex_password_here
```

### Network Security

```bash
# Isolate BMC network
# Configure dedicated VLAN for BMC access
# Restrict routing between BMC and production networks

# Use VPN for remote BMC access
# Monitor BMC access logs regularly
# Rotate BMC credentials periodically
```

## Troubleshooting Advanced Issues

### DPU Service Issues

```bash
# Check DPU deployment status
oc get dpudeployment -n dpf-operator-system

# Verify DPU network configuration
oc get sriovnetwork -n openshift-sriov-network-operator

# Debug DPU interface issues
oc debug node/worker-node
# Check DPU interfaces in debug shell
```

### Performance Issues

```bash
# Check resource usage
oc adm top nodes
oc adm top pods -n dpf-operator-system

# Verify network performance
# Run network performance tests between nodes
```

### Scale Issues

```bash
# Check cluster capacity
oc describe nodes | grep -A 5 Capacity

# Monitor hosted cluster resources
oc get hostedcluster -n clusters -o wide
```

## Next Steps

- **Monitoring**: Set up Prometheus monitoring for DPU metrics
- **Alerting**: Configure alerts for DPU service health
- **Backup**: Implement backup strategies for hosted clusters
- **Scaling**: Plan for horizontal and vertical scaling

For complex customization needs, refer to the [NVIDIA DPF Documentation](https://docs.nvidia.com/networking/display/dpf2504/) and [Red Hat OpenShift Documentation](https://docs.openshift.com/).