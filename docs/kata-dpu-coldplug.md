# Kata DPU cold-plug: setup, debug, and runbook

Notes from bringing up `kata-dpu-test` on a DPU worker (`worker-303ea712f378` / nvd-srv-45). Host-side pieces come from [jensfr/rhcos-layer-kata-dpu](https://github.com/jensfr/rhcos-layer-kata-dpu/tree/dpu-coldplug-nvidia-ref). DPF-side pieces (PF1 VF pool, OVN injector mapping) live in this repo.

**Do not use `ovs-ctl` to restart OVS on DPUs.** It wipes the database. Use:

```bash
kd debug node/<dpu-node> -- chroot /host systemctl restart ovs-vswitchd
# or: systemctl restart openvswitch
```

`oc` = management cluster. `kd` = hosted/DOCA cluster (`oc --kubeconfig ~/.kube/doca.kubeconfig`).

---

## How it is supposed to work

1. DPF creates SR-IOV VFs on BlueField. `mlx5_core` binds and each VF gets a netdev.
2. Device plugin advertises PF0 netdev VFs (regular pods) and PF1 kata VFs (`openshift.io/bf3-p1-vfs-kata`).
3. Pod uses `runtimeClassName: kata-coldplug` and requests **one** kata VF (same as jensfr `05-test-pod.yaml`).
4. OVN injector webhook sets `v1.multus-cni.io/default-network` to the kata NAD.
5. CNI moves the VF **as a netdev** into the sandbox netns (VF must still be on `mlx5_core`).
6. Kata rebinds the VF `mlx5_core` → `vfio-pci`, cold-plugs it into QEMU.
7. Guest `mlx5_core` binds; kata agent applies captured IP/MAC/routes.

If step 6 happens **before** step 5 (or leftover `driver_override=vfio-pci`), CNI fails with `stat .../net: no such file or directory`.

Regular (non-kata) pods only prove the **PF0** path. Kata uses **PF1**.

---

## Env (`.env`)

```bash
KATA_SRIOV_DP_CONFIG_NAME=bf3-p1-vfs-kata
KATA_SRIOV_PF_INDEX=1
KATA_NUM_VFS=46
KATA_RUNTIME_CLASS=kata-coldplug
KATA_INJECTOR_RESOURCE_NAME=openshift.io/bf3-p1-vfs-kata
# Git default: dpf-ovn-kubernetes-${KATA_RUNTIME_CLASS}
# Override example seen on nvd-srv-45:
KATA_NAD_NAME=dpf-ovn-kubernetes-bf3-p1-vfs-kata
KATA_RHCOS_LAYER_IMAGE=quay.io/jensfr/rhcos-kata-dpu@sha256:ce05dea3e0214c7bf7864cef1110e414a6419430fe2f55b5e9c848b71b799a8f
KATA_SKIP_RHCOS_LAYER=false
```

NAD name does not have to match the RuntimeClass. Injector `runtimeClass` + `nadName` + `resourceName` must match the NAD and the pod resource.

---

## Bring-up

After DPF is up (`make all` includes `enable-ovn-injector`):

```bash
make enable-ovn-injector   # webhook + kata NAD (if not already done)
make enable-kata           # OSC, MC 99-kata-dpu, RuntimeClass, render test pod
```

`enable-kata` is **not** part of `make all`. MachineConfig goes on MCP `worker-dpu` (or `worker` on SNO). No KataConfig CR (avoids `kata-oc` clashing with `worker-dpu`).

Apply test pods (`KATA_TEST_REPLICAS` defaults to 1):

```bash
make deploy-kata-test
# or: KATA_TEST_REPLICAS=4 make deploy-kata-test
oc wait --for=condition=Available deployment/kata-dpu-test --timeout=180s
```

Re-apply `99-kata-dpu` after changing the MC (for example adding `vfio-pci` modules-load):

```bash
oc delete mc 99-kata-dpu
make enable-kata
# wait for MCP worker-dpu; node reboots
```

---

## Prerequisites on the worker (must all pass)

Run on the DPU host worker (debug node or SSH as core/root).

### VT-x / KVM

Kata needs `/dev/kvm`. This is **firmware**, not MachineConfig.

```bash
grep -c vmx /proc/cpuinfo          # must be > 0
ls -la /dev/kvm
dmesg | grep -iE 'kvm|vmx' | tail -10
systemd-detect-virt                # none = bare metal
```

Failure we hit:

```text
x86/cpu: VMX (outside TXT) disabled by BIOS
ls: cannot access '/dev/kvm': No such file or directory
```

Kata error: `failed to add any hypervisor device to devices cgroup` (that message is **KVM**, not VFIO).

Fix: BIOS → enable **Intel VT-x / Virtualization Technology**. VT-d (IOMMU) can already be on. Cold boot the **host**, not the DPU BMC.

### IOMMU

MC `99-kata-dpu` sets `intel_iommu=on iommu=pt`.

```bash
cat /proc/cmdline | tr ' ' '\n' | grep iommu
ls /sys/kernel/iommu_groups/ | wc -l
pci=$(basename $(readlink /sys/class/net/$(ls /sys/class/net | grep np1 | head -1)/device/virtfn0))
ls -la /sys/bus/pci/devices/$pci/iommu_group
```

Need non-empty groups and a symlink per kata VF.

### RHCOS kata layer

Layer ships patched `kata-containers-3.31.0-3` (same NVR as stock; `rpm -q` is **not** enough).

```bash
oc get mc 99-kata-dpu -o jsonpath='{.spec.osImageURL}{"\n"}'
rpm-ostree status
```

Expect a deployment on `quay.io/jensfr/rhcos-kata-dpu@sha256:ce05dea3...`.

### CRI-O / kata config

```bash
rpm -q kata-containers
rpm -q qemu-kvm-core
ls -la /usr/libexec/qemu-kvm
cat /etc/crio/crio.conf.d/50-kata-coldplug
cat /etc/kata-containers/config.d/50-coldplug.toml
```

Need `runtimeHandler=kata-coldplug`, `cold_plug_vfio = "root-port"`, `allowed_annotations` including `io.kubernetes.cri-o.Devices`.

### vfio-pci module

Without this, kata writes `driver_override=vfio-pci`, unbinds `mlx5_core`, then `drivers_probe` fails. Sandbox times out; VF is left UNBOUND.

```bash
lsmod | grep vfio_pci
ls /sys/bus/pci/drivers/vfio-pci/
modprobe vfio-pci   # until MC drop-in is rolled out
```

Persistent: `/etc/modules-load.d/kata-vfio.conf` in `manifests/kata/02-kata-machineconfig.yaml` (content `vfio-pci`). Apply by deleting `99-kata-dpu` and re-running `make enable-kata`.

---

## Webhook / NAD

```bash
grep -E 'KATA_NAD|KATA_RUNTIME|KATA_INJECTOR' .env
oc get net-attach-def -n openshift-ovn-kubernetes | grep -E 'kata|bf3-p1'
oc get runtimeclass kata-coldplug
```

Injector mapping (`scripts/enable-ovn-injector.sh`):

```text
runtimeClass  = ${KATA_RUNTIME_CLASS}              # kata-coldplug
nadName       = ${KATA_NAD_NAME}
resourceName  = ${KATA_INJECTOR_RESOURCE_NAME}     # openshift.io/bf3-p1-vfs-kata
```

Pod after admit should have:

```bash
oc get pod -l app=kata-dpu-test -o jsonpath='{.items[0].metadata.annotations.v1\.multus-cni\.io/default-network}{"\n"}'
oc get pod -l app=kata-dpu-test -o jsonpath='{.items[0].metadata.annotations.k8s\.ovn\.org/dpu\.connection-details}{"\n"}'
oc get pod -l app=kata-dpu-test -o jsonpath='{.items[0].metadata.annotations.k8s\.ovn\.org/dpu\.connection-status}{"\n"}'
```

Working example (jensfr demo / our success):

| Annotation | Example |
|------------|---------|
| `v1.multus-cni.io/default-network` | `openshift-ovn-kubernetes/dpf-ovn-kubernetes-kata-coldplug` (or your `KATA_NAD_NAME`) |
| `k8s.ovn.org/dpu.connection-details` | `{"default":{"pfId":"1","vfId":"...","vfNetdevName":"ens7f1v16"}}` |
| `k8s.ovn.org/pod-networks` | IP/MAC/gateway |
| `k8s.v1.cni.cncf.io/network-status` | kata NAD, `"default": true` |

`dpu.connection-status` should appear within ~30s. Empty + CNI timeout = DPU did not finish PF1 plumbing (not “DPU is down for PF0”).

---

## Find and fix stale VFIO VFs

Idle kata VFs must be `mlx5_core` with a netdev. Failed pods leave `driver_override=vfio-pci`.

```bash
# Devices currently on vfio-pci
ls /sys/bus/pci/drivers/vfio-pci/ 2>/dev/null | grep -E '^[0-9a-f]{4}:'

# Scan all VFs; print anything not mlx5_core
for pf in $(ls /sys/class/net | grep np); do
  echo "=== $pf ==="
  for vf in /sys/class/net/$pf/device/virtfn*; do
    pci=$(basename $(readlink $vf))
    driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver 2>/dev/null) 2>/dev/null || echo UNBOUND)
    override=$(cat /sys/bus/pci/devices/$pci/driver_override 2>/dev/null)
    net=$(ls /sys/bus/pci/devices/$pci/net 2>/dev/null | tr '\n' ' ')
    if [ "$driver" != "mlx5_core" ] || { [ -n "$override" ] && [ "$override" != "(null)" ]; }; then
      echo "$pci  driver=$driver  override=${override:-none}  net=${net:-NONE}"
    fi
  done
done
```

PF1 only:

```bash
for pf in $(ls /sys/class/net | grep np1); do
  for vf in /sys/class/net/$pf/device/virtfn*; do
    pci=$(basename $(readlink $vf))
    driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver 2>/dev/null) 2>/dev/null || echo UNBOUND)
    echo "$pf $pci $driver"
  done
done
```

Rebind one VF:

```bash
PCI=0000:b5:07.7
echo "" > /sys/bus/pci/devices/$PCI/driver_override
[ -e /sys/bus/pci/devices/$PCI/driver/unbind ] && echo $PCI > /sys/bus/pci/devices/$PCI/driver/unbind
echo $PCI > /sys/bus/pci/drivers/mlx5_core/bind
basename $(readlink /sys/bus/pci/devices/$PCI/driver)
ls /sys/bus/pci/devices/$PCI/net/
```

Rebind all stale VFs (`vfio-pci/unbind` missing is OK if the device is UNBOUND):

```bash
for pf in $(ls /sys/class/net | grep np); do
  for vf in /sys/class/net/$pf/device/virtfn*; do
    pci=$(basename $(readlink $vf))
    driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver 2>/dev/null) 2>/dev/null || echo UNBOUND)
    if [ "$driver" != "mlx5_core" ]; then
      echo "" > /sys/bus/pci/devices/$pci/driver_override
      [ -e /sys/bus/pci/devices/$pci/driver/unbind ] && echo $pci > /sys/bus/pci/devices/$pci/driver/unbind
      echo $pci > /sys/bus/pci/drivers/mlx5_core/bind 2>/dev/null
      echo "Fixed $pci"
    fi
  done
done
```

Always **delete the pod first**. A retrying `ContainerCreating` pod will immediately dirty the next VF.

From bastion:

```bash
oc debug node/worker-303ea712f378 -- chroot /host bash -c '
  ls /sys/bus/pci/drivers/vfio-pci/ 2>/dev/null | grep -E "^[0-9a-f]"
'
```

---

## DPU recovery after **host** reboot

Known DPF issue: after host reboot, DPU `br-dpu` loses IPv4 and **all** (non-hostNetwork) pods fail. Regular pods working means this is already recovered.

```bash
oc get secret doca-admin-kubeconfig -n dpf-operator-system \
  -o jsonpath='{.data.super-admin\.conf}' | base64 -d > /tmp/doca-kubeconfig.yaml

DPU_NODE=$(KUBECONFIG=/tmp/doca-kubeconfig.yaml oc get nodes \
  -o jsonpath='{.items[0].metadata.name}')

KUBECONFIG=/tmp/doca-kubeconfig.yaml oc debug node/$DPU_NODE -- \
  chroot /host systemctl restart openvswitch

HOST_IP=$(oc get node <host-node> -o jsonpath='{.status.addresses[0].address}')
KUBECONFIG=/tmp/doca-kubeconfig.yaml oc debug node/$DPU_NODE -- \
  chroot /host ip addr add $HOST_IP/32 dev br-dpu

KUBECONFIG=/tmp/doca-kubeconfig.yaml oc delete pod -n dpf-operator-system -l app=ovnkube-node
oc delete pod -n openshift-ovn-kubernetes -l app=ovnkube-node-dpu-host
```

Wait 2–3 minutes. Ping DPU gateway from the worker if you use that topology (`169.254.0.4` on some labs).

---

## Failures we actually hit

| Symptom | Cause | Fix |
|---------|--------|-----|
| `failed to add any hypervisor device to devices cgroup` | No `/dev/kvm` (VMX off in BIOS) | Enable VT-x, cold boot host |
| `stat /sys/bus/pci/devices/XXXX/net: no such file` | VF on vfio/UNBOUND before CNI | Rebind to `mlx5_core`; do not leave pod retrying |
| First CNI OK (`AddedInterface` kata NAD), then `create container timeout` | `vfio-pci` module not loaded | `modprobe vfio-pci`; persist via MC |
| Same netdev error on **new** PCI each retry | Cascade from first timeout | Delete pod, fix **all** stale VFs, then one retry |
| `timed out waiting for annotations` / missing `dpu.connection-status` | Host wrote `connection-details`; DPU never finished PF1 | Stop retries; DPU ovnkube logs; PF1 representors; bounce DPU ovnkube-node |
| `rpm -q kata-containers` shows `3.31.0-3` | Layer uses patched **same NVR** | Confirm with `rpm-ostree status`, not RPM name |

Kata shim log when vfio-pci is missing (success path until probe):

```text
Physical network interface found interface=eth0
Attaching endpoint endpoint-type=physical hotplug=false
Write vfio-pci to driver_override device-bdf=0000:b5:07.0
Unbinding device from driver
Writing bdf to drivers-probe-path
Removing network after failure in createSandbox
CreateContainer failed: create container timeout
```

CRI-O / kata logs:

```bash
journalctl -u crio --since "2 min ago" --no-pager | grep -iE 'error|timeout|kata|qemu|vfio|shim|sandbox|cold'
```

DPU ovnkube for this pod:

```bash
kd logs -n dpf-operator-system -l app=ovnkube-node --tail=200 \
  | grep -iE 'kata-dpu-test|ens7f1v16|pfId.:.1|connection'
```

PF1 representors on DPU:

```bash
DPU=$(kd get nodes -o jsonpath='{.items[0].metadata.name}')
kd debug node/$DPU -- chroot /host bash -c 'ls /sys/class/net | grep -E "pf1|p1vf" | head'
```

---

## Clean retry sequence

```bash
oc delete deploy kata-dpu-test --ignore-not-found
oc delete pod -l app=kata-dpu-test --ignore-not-found

# On worker: modprobe vfio-pci if needed, rebind stale VFs (commands above)

make deploy-kata-test
```

Do **one** attempt. If it fails, fix VFs before kubelet burns the pool.

---

## Verify a Running pod

The smoke-test image is netshoot (`ip`, `ping`, `iperf`). Guest driver/sysfs still matter:

```bash
oc exec deploy/kata-dpu-test -- ip addr show eth0
oc exec deploy/kata-dpu-test -- ip route
oc exec deploy/kata-dpu-test -- ping -c 3 8.8.8.8
oc exec deploy/kata-dpu-test -- cat /sys/class/net/eth0/operstate   # up
oc exec deploy/kata-dpu-test -- cat /sys/class/net/eth0/carrier     # 1
oc exec deploy/kata-dpu-test -- cat /proc/modules | grep mlx5      # mlx5_core in guest
```

On the worker, QEMU should show VFIO:

```bash
ps aux | grep qemu-kvm | grep -o 'vfio-pci,host=[^ ]*'
```

---

## Repo files

| Path | Role |
|------|------|
| `scripts/enable-kata.sh` | OSC, `99-kata-dpu`, RuntimeClass, render test pod |
| `scripts/enable-ovn-injector.sh` | Injector + kata NAD mapping |
| `manifests/kata/02-kata-machineconfig.yaml` | IOMMU kargs, CRI-O, coldplug.toml, `vfio-pci` modules-load, optional osImageURL |
| `manifests/kata/05-runtimeclass.yaml` | `kata-coldplug` |
| `manifests/kata/06-test-deployment.yaml` | kata-dpu-test Deployment (KATA_TEST_REPLICAS) |
| `manifests/post-installation/nodesriovdevicepluginconfig.yaml` | PF1 kata VF pool |
| `ci/env.defaults` | `KATA_*` variables |

Code change from this work: persist `vfio-pci` via `/etc/modules-load.d/kata-vfio.conf` in `99-kata-dpu` (commit `0c4b359` on `kata-support`).
