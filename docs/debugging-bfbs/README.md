# Debugging BFBs

Quick tips for debugging BFB and OS layer provisioning on a DPU.

Ignition generation happens in [dpf-hcp-provisioner-operator](oci://quay.io/lhadad/charts/dpf-hcp-provisioner-operator).

> Note: unit names, file paths, and the rest of the ignition contents can change between releases. Treat that repo as the source of truth — if anything below doesn't match what you see on the DPU, check there first.

## Watch the DPU's rshim console via its DMS pod

When SSH isn't available — early boot, no networking, BFB still installing — use the rshim serial console. The DMS pod for the DPU runs on the worker hosting it and has the rshim character device mounted in.

The pod has multiple containers (`dms`, `hostagent`, `rshim`). All of these commands target the `hostagent` container — it has both `/dev/rshim0/console` and the `/var/lib/dpf` hostPath mount we use to persist the log.

### 1. Find the DMS pod for the DPU

```bash
oc get pods -A -o wide | grep -i dms
```

DMS pods are in `dpf-operator-system` and named after the DPU; pick the one scheduled on the worker that owns the DPU you care about.

### 2. Exec in and attach to the rshim console

```bash
oc exec -it -n dpf-operator-system <dms-pod> -c hostagent -- screen /dev/rshim0/console
```

Use `Ctrl-A` then `K` to exit. If the host has multiple DPUs, the rshim index (`rshim0`, `rshim1`, …) maps to the DPU slot order — confirm with `ls /dev/rshim*`.

### 3. Capturing a full boot to a file

The kernel ring buffer for the current boot is on the DPU itself (`dmesg`); the rshim console only shows what's streaming *now*. Attach with `screen -L` *before* rebooting the DPU.

The `hostagent` container mounts the worker's `/var/lib/dpf` as a hostPath (the `dpf-local-dir` volume), so writing the log there means it survives pod restarts and lives on the worker's persistent storage. The same path is visible inside the pod and on the worker:

```bash
oc exec -it -n dpf-operator-system <dms-pod> -c hostagent -- screen -L -Logfile /var/lib/dpf/rshim-console.log /dev/rshim0/console
```

To run the capture detached so you can close the exec session:

```bash
oc exec -n dpf-operator-system <dms-pod> -c hostagent -- screen -dmS rshim -L -Logfile /var/lib/dpf/rshim-console.log /dev/rshim0/console
```

The screen process dies if the pod restarts. The log file will persist but to capture new activity you must restart it.

The log streams while screen runs, so from the worker you can:

```bash
ssh core@<worker-node> tail -f /var/lib/dpf/rshim-console.log
```

By default screen flushes the buffer every 10 seconds — set it at runtime with `Ctrl-A :logfile flush 1` (or `0` for unbuffered) if you need faster updates.

If `-Logfile` doesn't seem to do anything (older screen versions silently ignore it), `cd` into the target dir first and let screen write to its default `screenlog.0`:

```bash
oc exec -it -n dpf-operator-system <dms-pod> -c hostagent -- bash -c 'cd /var/lib/dpf && screen -L /dev/rshim0/console'
```

## Get a shell on the DPU

The DPU is reached from its host worker node over the `tmfifo_net0` link-local IPv6. To log in you need an SSH key on the worker.

### 1. Copy your private SSH key to the worker node
From a machine that can ssh into OpenShift worker nodes e.g. the hypervisor used to create the cluster:

```bash
scp ~/.ssh/id_rsa core@<worker-node>:~/.ssh/id_rsa 
ssh core@<worker-node> 'chmod 600 ~/.ssh/id_rsa'
```

### 2. SSH from the worker to the DPU

```bash
ssh core@<worker-node>
ssh core@fe80::2%tmfifo_net0
```

`fe80::2` is the DPU side of the `tmfifo_net0` link-local network; the `%tmfifo_net0` suffix scopes the address to that interface.

## Check if the OS layer was pulled

On the DPU run:

### Is the image present locally?

```bash
sudo podman images
```

### Did the pull unit succeed?

The units are `machine-config-daemon-pull.service` and `machine-config-daemon-bootupd.service`:

```bash
systemctl status machine-config-daemon-pull.service
sudo journalctl -u machine-config-daemon-pull.service -b --no-pager
systemctl status machine-config-daemon-bootupd.service
sudo journalctl -u machine-config-daemon-bootupd.service -b --no-pager
```

## Inspecting failed units

### List everything that failed this boot

```bash
systemctl --failed --no-pager
```

### Drill into a specific unit

For each failed unit, look at status (last few log lines + exit code), then the full journal:

```bash
systemctl status <unit>
sudo journalctl -u <unit> -b --no-pager
```

### Key units to check on a DPU

- `bfvcheck.service` — firmware and bootloader version check for BlueField
- `dpf-ovs.service` — DPF OVS setup
- `NetworkManager-wait-online.service` — blocks boot until NetworkManager reports online
- `ovsdb-server.service` — Open vSwitch database
- `set_emu_param.service` — collects BlueField sensor and FRU information
- `dpu-agent.service` — DPF DPU-side agent

## Overriding a systemd unit on RHCOS

`/usr/lib/systemd/system` is read-only on RHCOS, but `systemctl edit` writes a drop-in under `/etc/systemd/system/<unit>.service.d/` which takes precedence.

```bash
sudo systemctl edit <unit>.service
```

Add only the fields you want to override under the matching section. For list-valued fields (`ExecStart`, `Environment`, `After`, …) set the field to empty first to clear the inherited value, then re-set it:

```ini
[Service]
ExecStart=
ExecStart=/new/command
```

Apply:

```bash
sudo systemctl daemon-reload && sudo systemctl restart <unit>.service
```