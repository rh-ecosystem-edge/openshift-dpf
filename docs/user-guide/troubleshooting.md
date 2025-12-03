# Troubleshooting Guide

Quick solutions to common issues with OpenShift DPF automation deployments.

## Quick Diagnostic Commands

```bash
# Overall cluster health
oc get nodes
oc get pods --all-namespaces | grep -v Running | grep -v Completed

# DPF-specific status
oc get pods -n dpf-operator-system
oc get hostedcluster -n clusters
oc get dpudeployment -n dpf-operator-system

# Check automation status
make cluster-status
make worker-status
```

## Deployment Issues

### Cluster Creation Fails

**Problem**: `make create-cluster` fails or hangs

```bash
# Check aicli configuration
aicli list clusters

# Verify Red Hat credentials
cat ~/.aicli/config.yaml

# Check .env configuration
grep -E "CLUSTER_NAME|BASE_DOMAIN|OPENSHIFT_VERSION" .env

# Common fixes:
# 1. Verify internet connectivity
# 2. Check Red Hat account access
# 3. Ensure unique cluster name
# 4. Verify domain ownership
```

### VM Creation Fails

**Problem**: `make create-vms` fails

```bash
# Check libvirt status
sudo systemctl status libvirtd

# Verify available resources
free -h                      # Need 32GB+ RAM
df -h /var/lib/libvirt      # Need 200GB+ storage

# Check VM configuration
grep -E "VM_COUNT|RAM|VCPUS" .env

# Common fixes:
# 1. Increase host RAM/storage
# 2. Reduce VM_COUNT or RAM settings
# 3. Start libvirt service
# 4. Fix /var/lib/libvirt permissions
```

### DPF Installation Fails

**Problem**: `make deploy-dpf` fails

```bash
# Check prerequisite operators
oc get pods -n cert-manager
oc get pods -n openshift-nfd
oc get pods -n openshift-sriov-network-operator

# Verify pull secrets
oc get secret pull-secret -n dpf-operator-system -o yaml

# Check DPF operator logs
oc logs -n dpf-operator-system deployment/dpf-operator-controller-manager

# Common fixes:
# 1. Wait for prerequisites to be ready (5+ minutes)
# 2. Verify NGC pull secret credentials
# 3. Check internet connectivity from cluster
# 4. Verify DPF version compatibility
```

### Worker Provisioning Fails

**Problem**: Workers don't join cluster

```bash
# Check BMC connectivity
ping 192.168.1.101
curl -k https://192.168.1.101/redfish/v1/

# Check worker provisioning status
oc get bmh -n openshift-machine-api
oc get csr | grep Pending

# Check automation logs
oc logs -n openshift-machine-api deployment/metal3

# Common fixes:
# 1. Verify BMC credentials and IP
# 2. Check boot MAC address is correct
# 3. Manually approve CSRs if needed
# 4. Verify network connectivity to cluster
```

## Network Issues

### Cluster Network Not Accessible

**Problem**: Cannot reach cluster API

```bash
# Check cluster status
make cluster-status

# Verify VM network
virsh net-list
sudo ip addr show br-dpf

# Check cluster IPs
grep -E "API_VIP|INGRESS_VIP" .env

# Test cluster connectivity
ping ${API_VIP}
curl -k https://${API_VIP}:6443/healthz

# Common fixes:
# 1. Wait for cluster installation to complete
# 2. Verify network bridge configuration
# 3. Check firewall rules
# 4. Restart libvirt networking
```

### DPU Network Issues

**Problem**: DPU interfaces not configured

```bash
# Check SR-IOV operator status
oc get pods -n openshift-sriov-network-operator

# Verify DPU interface configuration
oc get sriovnetworkpolicy -n openshift-sriov-network-operator
oc get sriovnetwork -n openshift-sriov-network-operator

# Check DPU interface on worker nodes
oc debug node/worker-01
chroot /host
ip link show | grep ens7f0

# Common fixes:
# 1. Wait for SR-IOV operator to configure interfaces (10+ minutes)
# 2. Verify DPU_INTERFACE setting in .env
# 3. Check DPU hardware is properly installed
# 4. Verify NUM_VFS configuration
```

## Storage Issues

### Persistent Volume Issues

**Problem**: Pods stuck in Pending state due to storage

```bash
# Check storage class
oc get storageclass

# For SNO/single-node (uses LVMS)
oc get pods -n openshift-local-storage

# For multi-node (uses ODF)
oc get pods -n openshift-storage

# Check available storage
oc get pv
oc get pvc --all-namespaces

# Common fixes:
# 1. Wait for storage operators to be ready (10+ minutes)
# 2. Verify disk space on nodes
# 3. Check storage operator logs
# 4. For multi-node: ensure 3+ worker nodes
```

## Performance Issues

### Slow Deployment

**Problem**: Deployment takes longer than expected

```bash
# Check resource usage on host
top
iostat 1        # Check disk I/O
free -h         # Check memory usage

# Check cluster resource usage
oc adm top nodes
oc adm top pods -n dpf-operator-system

# Common fixes:
# 1. Allocate more RAM to VMs
# 2. Use faster storage (SSD)
# 3. Increase CPU cores
# 4. Close other applications
```

### DPU Performance Issues

**Problem**: Poor DPU performance

```bash
# Check DPU utilization
oc get dpudeployment -n dpf-operator-system -o wide

# Verify SR-IOV VF allocation
oc describe node worker-01 | grep "openshift.io/bf3"

# Test DPU networking
# Run network performance tests between DPU-enabled pods

# Common optimizations:
# 1. Tune NUM_VFS for your workload
# 2. Enable jumbo frames (NODES_MTU=9000)
# 3. Optimize DPU interface settings
# 4. Check for hardware issues
```

## Configuration Issues

### Environment Variables

**Problem**: Invalid configuration values

```bash
# Validate .env configuration
make validate-environment

# Check for common issues
grep -E "^[A-Z_]+=.*[[:space:]]" .env    # Trailing spaces
grep -E "^[A-Z_]+=$" .env                # Empty values

# Verify required variables are set
grep -E "CLUSTER_NAME|BASE_DOMAIN|OPENSHIFT_VERSION" .env

# Common issues:
# 1. Trailing spaces in values
# 2. Empty required variables
# 3. Invalid IP addresses or hostnames
# 4. Conflicting network ranges
```

### Pull Secret Issues

**Problem**: Image pull failures

```bash
# Check pull secret format
jq . openshift_pull.json
cat pull-secret.txt

# Verify pull secret is applied
oc get secret pull-secret -n dpf-operator-system

# Test NGC registry access
podman login nvcr.io --username '$oauthtoken' --password-stdin < pull-secret.txt

# Common fixes:
# 1. Re-download Red Hat pull secret
# 2. Verify NGC API key is valid
# 3. Merge pull secrets correctly
# 4. Check internet connectivity
```

## Recovery Procedures

### Clean Recovery

**Problem**: Need to start completely fresh

```bash
# Complete cleanup (WARNING: Destroys everything)
make clean-all
make delete-cluster
make delete-vms

# Remove any leftover resources
sudo virsh net-destroy dpf-net 2>/dev/null || true
sudo virsh net-undefine dpf-net 2>/dev/null || true

# Start fresh
cp .env.example .env
# Edit .env with your settings
make all
```

### Partial Recovery

**Problem**: Need to recover specific component

```bash
# Recreate VMs only
make delete-vms
make create-vms

# Redeploy DPF only
oc delete namespace dpf-operator-system
make deploy-dpf

# Re-provision workers only
make delete-workers  # If target exists
make add-worker-nodes
```

## Getting Help

### Log Collection

```bash
# Collect automation logs
make collect-logs > dpf-deployment.log 2>&1

# Collect cluster logs
oc adm must-gather --image=quay.io/openshift/origin-must-gather

# Collect DPF-specific logs
oc logs -n dpf-operator-system deployment/dpf-operator-controller-manager > dpf-operator.log
```

### Debug Mode

```bash
# Enable debug output for automation
export DEBUG=true
make deploy-dpf

# Verbose OpenShift commands
oc get pods -v=6
oc describe node worker-01
```

### Common Error Patterns

| Error Message | Likely Cause | Quick Fix |
|--------------|---------------|-----------|
| "connection refused" | Service not ready | Wait 5+ minutes |
| "pull secret" | Registry auth issue | Check pull secrets |
| "no such host" | DNS/network issue | Check network config |
| "insufficient resources" | Resource limits | Increase RAM/CPU |
| "timeout" | Process taking too long | Wait or check logs |

## Next Steps

If you can't resolve the issue:

1. **Check logs**: Collect relevant logs using commands above
2. **Search documentation**: Check other guides for specific topics
3. **File issue**: Report the problem with logs and configuration
4. **Community**: Ask for help in project discussions

For complex issues, include your `.env` configuration (remove sensitive data) and relevant log outputs.