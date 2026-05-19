# Redfish Worker Provisioning

Provision physical servers as OpenShift worker nodes using direct Redfish API calls — no Bare Metal Operator (BMO) or Ironic required.

This is an alternative to the default BMO/BMH provisioning path. It uses Redfish VirtualMedia to mount the day2 discovery ISO directly onto the server's BMC, sets a one-time boot override via Redfish, and lets the Assisted Installer handle the rest.

## Prerequisites

### HTTP Server for ISO Serving

BMCs on management networks typically cannot reach external URLs (e.g. `api.openshift.com`). The day2 ISO must be served from an HTTP server that the BMC can reach.

**You are responsible for setting up the HTTP server.** The automation will download the ISO to the path you configure — it does not manage nginx, Apache, or any HTTP daemon.

#### Mode 1: Local HTTP Server

The HTTP server runs on the same machine as the automation. The ISO is downloaded directly to the local filesystem.

```
┌─────────────────────────┐
│  Automation Host        │
│  ┌───────────────────┐  │
│  │ HTTP server       │  │         ┌─────┐
│  │ serving /dpf-iso/ │──────────▶│ BMC │
│  └───────────────────┘  │         └─────┘
│  make add-worker-nodes  │
└─────────────────────────┘
```

Example setup:
```bash
# Install and start nginx
sudo dnf install -y nginx
sudo mkdir -p /usr/share/nginx/html/dpf-iso
sudo systemctl enable --now nginx

# .env config
REDFISH_ISO_BASEURL=http://<your-ip>/dpf-iso
REDFISH_ISO_HOSTPATH=/usr/share/nginx/html/dpf-iso
REDFISH_ISO_HOST=
```

#### Mode 2: Remote HTTP Server

The HTTP server runs on a different machine. The ISO is downloaded via SSH (`ssh <host> wget ...`).

```
┌──────────────────┐       SSH        ┌──────────────────┐
│ Automation Host  │─────────────────▶│ Remote HTTP Host │
│                  │                  │ ┌──────────────┐ │       ┌─────┐
│ make add-worker  │                  │ │ HTTP server  │─┼──────▶│ BMC │
│                  │                  │ │ /dpf-iso/    │ │       └─────┘
└──────────────────┘                  │ └──────────────┘ │
                                      └──────────────────┘
```

Example setup:
```bash
# On the remote host: install and start nginx
sudo dnf install -y nginx
sudo mkdir -p /usr/share/nginx/html/dpf-iso
sudo systemctl enable --now nginx

# .env config (on automation host)
REDFISH_ISO_BASEURL=http://<remote-http-ip>/dpf-iso
REDFISH_ISO_HOSTPATH=/usr/share/nginx/html/dpf-iso
REDFISH_ISO_HOST=root@remote-http-host
```

## Configuration

### .env Variables

```bash
# --- Provisioning method ---
# Set to "redfish" to use direct Redfish provisioning instead of BMO
WORKER_PROVISION_METHOD=redfish

# --- Workers (same pattern as BMO, but BOOT_MAC is not required) ---
WORKER_COUNT=1
WORKER_1_NAME=worker-01
WORKER_1_BMC_IP=10.26.16.27
WORKER_1_BMC_USER=root
WORKER_1_BMC_PASSWORD=***

# --- ISO HTTP serving ---
# URL prefix the BMC will use to fetch the ISO via VirtualMedia
REDFISH_ISO_BASEURL=http://10.8.231.20/dpf-iso

# Filesystem path where the ISO is stored (must be served by the HTTP server above)
REDFISH_ISO_HOSTPATH=/usr/share/nginx/html/dpf-iso

# SSH target for the HTTP server host (empty = local)
REDFISH_ISO_HOST=root@10.8.231.20
```

### Variable Reference

| Variable | Required | Description |
|----------|----------|-------------|
| `WORKER_PROVISION_METHOD` | Yes | Set to `redfish` (default: `bmo`) |
| `WORKER_n_NAME` | Yes | Unique hostname for the worker |
| `WORKER_n_BMC_IP` | Yes | BMC/iDRAC management IP |
| `WORKER_n_BMC_USER` | Yes | BMC username |
| `WORKER_n_BMC_PASSWORD` | Yes | BMC password |
| `REDFISH_ISO_BASEURL` | Yes | HTTP base URL the BMC fetches the ISO from |
| `REDFISH_ISO_HOSTPATH` | Yes | Filesystem path backing that URL |
| `REDFISH_ISO_HOST` | No | SSH target for the HTTP server (empty = local) |

> **Note:** `WORKER_n_BOOT_MAC` is not required for Redfish provisioning. The ISO is mounted via VirtualMedia, not PXE.

## Usage

```bash
# Verify Redfish connectivity to all configured BMCs
make redfish-verify

# Check power state
make redfish-power-status

# Provision workers (full flow: ISO mount → Redfish boot → AI register → install → CSR approve)
make add-worker-nodes
```

## How It Works

1. **Verify** — Connects to each BMC via Redfish API and confirms reachability
2. **Day2 cluster** — Creates the Assisted Installer day2 environment
3. **Download ISO** — Gets the day2 discovery ISO and places it on the HTTP server (`wget` locally or `ssh <host> wget` remotely)
4. **Mount ISO** — Mounts the ISO on each BMC via Redfish VirtualMedia (InsertMedia)
5. **Power off** — Gracefully powers off the server via Redfish (ForceOff) to ensure clean boot state
6. **Boot override** — Sets one-time boot to virtual CD via Redfish (`BootSourceOverrideTarget: Cd`)
7. **Power on** — Powers on the server via Redfish
8. **Wait for registration** — Polls Assisted Installer until the host appears with status `known`
9. **Bind and start** — Binds the host to the cluster and starts installation via `aicli`
10. **Wait for install** — Polls until installation completes (status `added-to-existing-cluster`)
11. **Eject ISO** — Ejects VirtualMedia so the post-install reboot goes to the installed OS, not back to the discovery ISO
12. **CSR approval** — Approves pending certificate signing requests and waits for the node to become `Ready`

## Troubleshooting

### BMC reachable via Redfish but server boots from RAID instead of ISO

Verify the Redfish boot override is set correctly:

```bash
curl -sk -u user:pass \
  https://<BMC_IP>/redfish/v1/Systems/System.Embedded.1 | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Boot'])"
```

Expected: `BootSourceOverrideTarget: Cd`, `BootSourceOverrideEnabled: Once`. If the server still boots from RAID, ensure it was **powered off** before setting the boot override — some BMC firmware ignores overrides set while the server is on.

### VirtualMedia insert fails with "detached" error

The ISO may already be mounted from a previous attempt. Eject it first:

```bash
curl -sk -u user:pass -X POST \
  https://<BMC_IP>/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia \
  -H "Content-Type: application/json" -d '{}'
```

### Host never appears in Assisted Installer

- Check BMC console — did the server actually boot from the ISO?
- Verify the ISO URL is reachable from the BMC network: `curl -I http://<ISO_URL>/cluster-day2.iso`
- Ensure the HTTP server is running and the ISO file exists at `REDFISH_ISO_HOSTPATH`

### iDRAC becomes unresponsive

Rapid-fire Redfish API calls can crash the iDRAC webserver. Wait 5–10 minutes for it to recover, or perform an iDRAC reset from the physical server's front panel.
