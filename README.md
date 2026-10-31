# OpenShift DPF and NNO Automation

Automation for creating Red Hat OpenShift clusters for NVIDIA DPF (DPU Platform
Framework) on Red Hat OpenShift clusters with NVIDIA BlueField-3 DPUs and NVIDIA Network Operator (NNO) deployments.

## 🚀 Quick Deployment

**One command runs the complete DPF deployment:**
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

### Zero Trust DPU BMC Prerequisites

DPF enables RShim on the DPU BMC during provisioning. If you need it for
debugging later, enable it manually on that DPU BMC after provisioning.

Complete these manual steps on every DPU BMC before running `make all-zt`:

1. Configure the same `root` password on every DPU BMC. Set
   `ZT_DPU_BMC_ROOT_PASSWORD` to this password when generating `.env`.
2. Verify that the BMC Redfish endpoint is reachable. This command prompts for
   the shared `root` password instead of putting it in the shell history:

   ```bash
   curl -k -u root https://<DPU_BMC_IP>/redfish/v1/Systems/Bluefield
   ```

4. Set `ZT_DPU_BMC_IP_RANGE_START` and `ZT_DPU_BMC_IP_RANGE_END`. A
   `DPUDiscovery` scans this inclusive range and creates a `DPUDevice` for
   every DPU BMC it finds. Scans repeat every three minutes by default;
   override this with `ZT_DPU_DISCOVERY_SCAN_INTERVAL`. Only one range is
   supported. The DPU addresses may have gaps within it; every address in the
   range is scanned.
5. List the DPU BMC IPs of every host in `WORKER_<N>_DPU_BMC_IPS`,
   comma-separated without spaces, for example
   `WORKER_1_DPU_BMC_IPS=10.6.136.33` or
   `WORKER_2_DPU_BMC_IPS=10.6.136.34,10.6.136.35` for a host with two DPUs.
   Every address must be inside the discovery range, and each host with DPUs
   needs `WORKER_<N>_DPU=true` and its `WORKER_<N>_BMC_*` values. Hosts 1-5
   are supported, since the HBN VLANs and BGP AS numbers are derived from
   `N`. DPU serials are not required: discovery reads them from the DPU BMC.

Discovery does not create `DPUNode` resources (`skipDPUNodeDiscovery: true`).
The automation creates one `DPUNode` per host, `dpu-node-worker-<N>`, that
lists the `DPUDevice` discovered at each of the host's DPU BMC IPs. The DPUs
are named `dpu-node-worker-<N>-<serial>`. A discovered `DPUDevice` whose
address is not listed for any host is reported and is not provisioned.

Zero Trust DPU nodes use a `custom-reboot-script` ConfigMap based on NVIDIA's
example. The controller creates `<dpunode-name>-script-job` when reboot handling
is needed. The Job uses `ZT_DPU_REBOOT_IMAGE`, a small image containing Bash and
`ipmitool`, and performs the requested reset or power cycle through the matching
physical host BMC: `dpu-node-worker-<N>` uses the `WORKER_<N>_BMC_*` values.
`PowerCycle` uses `chassis power cycle`; the warm-reset methods use
`chassis power reset`; and `NoAction` exits without contacting the BMC.

With `VERIFY_DEPLOYMENT=true`, `make all-zt` and `make scale-out-zt-dpus` end
by waiting for every DPU listed in `WORKER_<N>_DPU_BMC_IPS` to reach phase
`Ready` and join the hosted cluster as a Ready Node, for the DPUDeployment to
be Ready, and for the management and hosted cluster operators to be stable.
The DPU and DPUDeployment waits are `VERIFY_MAX_RETRIES` x
`VERIFY_SLEEP_SECONDS` each (30 minutes by default). On timeout it prints each
DPU's phase and failing conditions, and the target fails. Run
`make verify-zt-deployment` to check an existing deployment.

### Scaling Out Zero Trust DPUs

Add `WORKER_<N>_DPU_BMC_IPS` for each new host to the inputs used to generate
`.env`. Ensure `WORKER_COUNT` includes every physical worker with DPUs and
configure its numbered `WORKER_<N>_BMC_*` variables. Regenerate `.env`, then
run:

```bash
source user.env
make generate-env FORCE=true
make scale-out-zt-dpus
```

The target checks every configured physical worker and powers on only those that
are off. It then waits for every configured DPU Redfish endpoint, waits for
discovery to create their `DPUDevice` resources, creates the missing host
`DPUNode` resources, and refreshes the HBN per-DPU configuration. Existing
IPAM, NAD, interface, and service-chain resources automatically reconcile for
the new DPUs. An existing `DPUNode` is not changed: to change the DPUs of a host
that is already deployed, scale it in first.

### Scaling In Zero Trust DPUs

Scale-in works per host. Clear or change the host's `WORKER_<N>_DPU_BMC_IPS` in
the inputs used to generate `.env`, regenerate `.env`, then pass the host's
`DPUNode` explicitly. At least one host must keep its DPUs listed:

```bash
source user.env
make generate-env FORCE=true
make scale-in-zt-dpus DPU_NODE=dpu-node-worker-2
```

The target removes the `DPUNode` from the DPUDeployment selector, waits for its
DPUs to be deleted, removes the `DPUNode` and its `DPUDevice` resources, and
refreshes the HBN configuration. Discovery recreates the `DPUDevice` of a DPU
whose address stays in the range within `ZT_DPU_DISCOVERY_SCAN_INTERVAL`, but
nothing provisions it while no host lists it. To take a DPU out of DPF
completely, for example to decommission it or to work on its BMC, move its BMC
IP outside `ZT_DPU_BMC_IP_RANGE_START`-`ZT_DPU_BMC_IP_RANGE_END`. To remove one
DPU from a host with several, list the remaining addresses,
run scale-in, then run `make scale-out-zt-dpus`; the remaining DPUs are
provisioned again. The target does not power off the physical worker.

### Zero Trust Single-Node OpenShift

Set `VM_COUNT=1` to use an SNO management cluster. `API_VIP` and `INGRESS_VIP`
are not required. `HYPERSHIFT_API_IP` is ignored, MetalLB is skipped, and the
hosted control plane uses `SingleReplica`.

Add the SNO management-node network configuration to `user.env`:

```bash
# Zero Trust SNO management cluster
export VM_COUNT=1
export VM_STATIC_IP=true
export VM_EXT_IPS=10.6.135.30
export VM_EXT_PL=24
export VM_GW=10.6.135.254
export VM_DNS=10.11.5.160
```

Replace the example values with the environment's reserved SNO address,
prefix length, gateway, and DNS server. The address in `VM_EXT_IPS` must be
unused before deployment, and DNS must resolve
`api.<CLUSTER_NAME>.<BASE_DOMAIN>` to that address so DPUs can reach the
management API.

Generate `.env` and confirm that the static network values were preserved:

```bash
source user.env
make generate-env FORCE=true
grep -E '^VM_(COUNT|STATIC_IP|EXT_IPS|EXT_PL|GW|DNS)=' .env
```

The DPU BMCs must still reach the BFB registry. By default, manifest
preparation resolves `HOST_CLUSTER_API` to the SNO management-node address
after `make update-etc-hosts`. Multi-node deployments use
`HYPERSHIFT_API_IP` for the registry address.

### Network Paths for the Zero Trust Automation

These are the network paths this automation (`make all-zt`) needs. They
describe the automation's lab flow, not the requirements of a production Zero
Trust deployment.

- The machine running `make` reaches each host BMC (`WORKER_<N>_BMC_IP`) over
  IPMI (UDP 623), to power the hosts on in `all-zt` and off in `clean-all`.
- The machine running `make` reaches each DPU BMC over Redfish (HTTPS), to wait
  for the DPU BMCs after power-on.
- The management cluster reaches each DPU BMC over Redfish (HTTPS), for DPU
  discovery and the BFB install.
- Management cluster pods, on any node, reach each host BMC over IPMI
  (UDP 623): the reboot Job resets or power-cycles the host.
- Each DPU BMC reaches the BFB registry over HTTP at `HYPERSHIFT_API_IP` (SNO:
  the management node address), port `ZT_BFB_REGISTRY_PORT` (default 8086), to
  download the BFB.
- The DPUs reach the container image registries over HTTPS.

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

# Essential settings (DPF is the default profile):
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
   # DPF is the default; set DEPLOYMENT_PROFILE only when using NNO
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

### Deployment profiles

`DEPLOYMENT_PROFILE` accepts `dpf` or `nno` and defaults to `dpf`.

- `dpf` keeps the complete existing deployment and uses `make all`.
- `nno` creates a base OpenShift cluster through worker provisioning and
  skips DPF-only requirements and manifests, including the NFD operator.

Generate an NNO environment rather than editing `.env` manually:

```bash
export DEPLOYMENT_PROFILE=nno
export CLUSTER_NAME=my-nno-cluster
export BASE_DOMAIN=example.com
export VM_COUNT=1
export OPENSHIFT_PULL_SECRET=openshift_pull.json

make generate-env FORCE=true
make create-base-cluster
```

For a multi-node cluster, also set `API_VIP` and `INGRESS_VIP`. See the
[NNO base cluster guide](docs/user-guide/nno-base-cluster.md) for
the complete workflow and instructions for switching an existing environment.

## 📖 Documentation

| Guide | Purpose |
|-------|---------|
| **[Getting Started](docs/user-guide/getting-started.md)** | Step-by-step setup guide |
| **[NNO Base Cluster](docs/user-guide/nno-base-cluster.md)** | Create a base OpenShift cluster for NNO |
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
make clean-all                           # Complete cleanup, including physical worker power off
make clean-all POWER_OFF_WORKERS=false   # Complete cleanup, leave physical workers powered on
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
