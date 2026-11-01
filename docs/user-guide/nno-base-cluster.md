# NNO Base Cluster

Use the `nno` deployment profile to create a base OpenShift cluster for
NVIDIA Network Operator (NNO) without requiring DPF-specific configuration or
installing DPF-specific prerequisites.

This flow creates the cluster and optionally provisions physical workers. It
does not deploy NNO itself yet.

## Generate the environment

The root `.env` file is generated. Do not add or prepend values to it manually;
duplicate entries are accepted by Make, and the last entry silently wins.

For a multi-node cluster:

```bash
export DEPLOYMENT_PROFILE=nno
export CLUSTER_NAME=my-nno-cluster
export BASE_DOMAIN=example.com
export VM_COUNT=3
export API_VIP=192.0.2.10
export INGRESS_VIP=192.0.2.11
export OPENSHIFT_PULL_SECRET=openshift_pull.json

make generate-env FORCE=true
```

For Single-Node OpenShift, set `VM_COUNT=1` and omit `API_VIP` and
`INGRESS_VIP`.

The NNO profile does not require:

- `DPU_HOST_CIDR`
- `BFB_URL`
- `DPF_PULL_SECRET`

Unless explicitly overridden, VM names use the `vm-nno` prefix.

Confirm the generated profile and VM names before provisioning:

```bash
grep -nE '^(DEPLOYMENT_PROFILE|VM_PREFIX|VM_WORKER_PREFIX)=' .env
```

There should be exactly one entry for each variable.

## Create the base cluster

```bash
make create-base-cluster
```

This runs, in order:

```text
verify-files
check-cluster
create-vms
prepare-manifests
cluster-install
update-etc-hosts
kubeconfig
poweron-workers
add-worker-nodes
verify-workers
```

`poweron-workers`, `add-worker-nodes`, and `verify-workers` are no-ops when `WORKER_COUNT=0`. Set
the `WORKER_*` variables before generating `.env` to join physical workers as
part of this target. NNO workers use the regular BareMetalHost template unless
you set `WORKER_n_DPU=true`.

The target is profile-aware. With the default `DEPLOYMENT_PROFILE=dpf` it still
stops after worker provisioning, so it is a useful cluster checkpoint before
the rest of `make all` deploys DPF.

The shared manifest preparation installs cluster monitoring. The NNO profile
skips the NFD operator (a subscription without the NFD CR breaks later NNO
install), DPF cert-manager, DPU worker manifests, and storage intended for
DPF hosted-cluster etcd.

Set `SKIP_ETC_HOSTS=true` while generating `.env` when the cluster API name is
already resolvable and `/etc/hosts` should not be changed.

## Switching an existing environment

To preserve the values from an existing generated `.env` while changing the
profile, load it into the shell, clear the derived VM prefixes, and regenerate:

```bash
set -a
source .env
set +a
unset VM_PREFIX VM_WORKER_PREFIX
export DEPLOYMENT_PROFILE=nno
make generate-env FORCE=true
```

Do this before creating VMs. Do not change `VM_PREFIX` in the middle of a run;
later VM discovery and cleanup must use the prefix with which the VMs were
created.

The existing `make all` target remains the complete DPF deployment. Use
`make create-base-cluster` for the NNO profile.

## Optional initial installation with physical workers

`WORKER_PROVISIONING_MODE=day1-assisted` installs the three control-plane VMs
and configured regular physical workers in one Assisted Installer deployment.
This is an experimental, opt-in path for a **new** NNO cluster. The default
remains `day2-bmo` for both profiles, including old generated environments that
omit this setting. DPF users continue to start with `make all` as before.

Select the mode before generating the environment and creating the cluster:

```bash
export DEPLOYMENT_PROFILE=nno
export WORKER_PROVISIONING_MODE=day1-assisted
export WORKER_BOOT_METHOD=redfish-virtualmedia
export VM_COUNT=3
export VM_WORKER_COUNT=0
export WORKER_COUNT=2

# Export CLUSTER_NAME, BASE_DOMAIN, API_VIP, INGRESS_VIP, OPENSHIFT_PULL_SECRET,
# SSH_KEY (a .pub file), and the existing WORKER_1_* / WORKER_2_* inputs.
# Supply BMC credentials through your private environment, without shell tracing.
# If discovery advertises multiple systems or media slots, also export the
# WORKER_n_REDFISH_SYSTEM_PATH / WORKER_n_REDFISH_VIRTUAL_MEDIA_PATH selections.
make generate-env FORCE=true
make create-base-cluster
```

The same ordered workflow runs under `make -j8 create-base-cluster`. It checks
configuration and BMC capabilities, creates an initial cluster and InfraEnv,
boots the control-plane VMs and physical workers using that discovery image,
uploads the profile-aware manifests, configures roles/hostnames/disks, and
waits for the exact configured inventory before starting installation once.
It then downloads access credentials, checks each configured node's role and
Ready condition, waits for management-cluster health, and ejects owned media.
It does not use BMO to provision workers, deploy a worker CSR approver, or install
NNO. OpenShift can still contain externally provisioned, unmanaged BareMetalHost
inventory entries, as observed in the lab installation; those are not BMO worker
provisioning requests.

### Implementation and boot methods

There are three day-1 helper files:

- `scripts/assisted-cluster.sh` loads repository configuration and reuses the
  existing libvirt, network-generation, manifest and power-control helpers.
- `scripts/assisted_install.py` coordinates aicli's JSON commands. It adds the
  exact-host start gate, role/disk configuration, owned state for safe reruns,
  node verification and cleanup. aicli remains the Assisted Installer client;
  the one direct API operation selects an exact disk ID using aicli's installed
  client and authentication, because its CLI rewrites disk paths.
- `scripts/assisted_redfish.py` implements the `redfish-virtualmedia` boot
  method. It discovers standard resources and actions; no Dell URLs or model
  checks are built into the implementation.

`WORKER_BOOT_METHOD` defaults to `redfish-virtualmedia` and is used only by
`day1-assisted`. It selects a boot implementation with configuration validation,
read-only preflight, discovery boot and owned cleanup operations. Another boot
method can be added at that boundary without changing the Assisted Installer
host gate. Unsupported methods fail validation before any hardware changes.
The chosen method is recorded with media ownership and cannot change while
that ownership remains. Older records without a method retain Redfish behavior.

Resource paths are deployment configuration. For example, a Dell environment
with multiple media slots can export the following before generating `.env`:

```bash
export WORKER_1_REDFISH_VIRTUAL_MEDIA_PATH=/redfish/v1/Systems/System.Embedded.1/VirtualMedia/1
export WORKER_2_REDFISH_VIRTUAL_MEDIA_PATH=/redfish/v1/Systems/System.Embedded.1/VirtualMedia/1
```

The generator preserves these settings, so both startup and cleanup use plain
Make targets. Use paths advertised by the target BMC; the example paths are
not defaults for other vendors. Dell iDRAC is the only hardware-tested
environment so far; generic Manager media and Dell's dual-collection layout
were also checked with disposable offline fixtures during development.

### Requirements and supported scope

- Three control-plane VMs and regular physical workers of the same architecture.
  SNO, worker VMs, mixed architectures, and physical-worker static addresses are
  outside this mode. `WORKER_COUNT=0` requires no BMC inputs or worker boot calls.
- DHCP on each worker boot NIC, with `NODES_MTU=1500` or `9000`. Configure
  `WORKER_n_BOOT_MAC` from the server's data NIC, rather than the BMC interface.
- A unique, lowercase single-label `WORKER_n_NAME` of at most 63 characters,
  BMC address/user/password, and boot MAC for every index through `WORKER_COUNT`.
  Environment generation uses the existing two worker blocks in `ci/env.template`.
  `WORKER_n_DPU` must be false or omitted; DPU and zero-trust settings are rejected.
- `WORKER_n_ROOT_DEVICE` defaults to `/dev/sda`. Paths, including `/dev/disk/by-id`
  and `/dev/disk/by-path` entries, must resolve to exactly one eligible disk in
  discovered inventory. The installer receives that disk's exact ID.
- Redfish virtual CD/DVD insertion/ejection and one-time `Cd` boot, with advertised
  power-on and restart actions. Multiple systems require
  `WORKER_n_REDFISH_SYSTEM_PATH`. If several usable media devices are advertised,
  set `WORKER_n_REDFISH_VIRTUAL_MEDIA_PATH` to the intended resource path from
  the diagnostic. For example, newer Dell iDRACs expose system slots
  `/redfish/v1/Systems/System.Embedded.1/VirtualMedia/1` and `/2` alongside the
  legacy Manager CD resource. Select one explicitly; the helper does not assume
  those resources are aliases. Export the selection before generating `.env`;
  runtime Make arguments are not required. The selected endpoint is pinned in lifecycle state
  when media insertion begins and reused for reruns and cleanup; changing it
  while media ownership exists is rejected.
  Existing media and boot overrides must be empty or owned by this workflow.
- TLS verification is enabled for automation-to-BMC connections. Set
  `REDFISH_CA_BUNDLE` for a private CA, or explicitly set `REDFISH_INSECURE=true`
  in a lab. Combining both is rejected. The BMC must separately trust the ISO
  server and fetch its URL, including redirects and signed query parameters.
- Discovery-image URLs must use HTTPS. The hypervisor downloader also rejects
  redirects to HTTP, so a signed image URL is not sent over plaintext transport.
- The automation environment needs Python 3 with PyYAML, `aicli` with its
  `assisted-service-client` dependency, curl, GNU userland, and the existing
  libvirt/SSH/oc tools. The exact disk-ID adapter uses the interpreter from the
  installed `aicli` entry point and its existing `AI_*` authentication settings
  and token store. No additional credentials are configured.

The BMC fetches its own ISO from Assisted Installer. `ISO_FOLDER` is only the
local or remote hypervisor's VM-side download location; it is not an HTTP
server. This mode does not start an image server or fall back to a console web
page. BMCs unable to consume the returned signed URL need a separately designed
and validated image-hosting solution before this flow can be used.

Control-plane static addresses, DNS, and routes remain in `STATIC_NET_FILE`.
Worker DHCP/MTU entries are added to a separate combined InfraEnv network file,
matched by MAC rather than the VM's `PRIMARY_IFACE`. Physical-worker entries
are never passed to the VM-creation loop.

### Resume, status, and removal

Run `make create-base-cluster` again after fixing discovery or validation
failures. Registered workers keep their boot sessions. A persisted boot request
with an uncertain BMC response preserves discovery media and one-time boot,
and is not automatically repeated; inspect the server and installer before
explicit teardown or retry. A reset explicitly rejected by the BMC remains
retryable after correcting the reported error. Cleanup refuses a boot override
changed from the owned one-time CD selection. In-progress
installations are monitored without changing media, roles, disks, or calling
start again. Installed reruns verify nodes and finish owned cleanup.

The workflow retains pinned cluster/InfraEnv/host IDs, the expected inventory,
and media ownership hashes in the ignored `.assisted-day1/` directory, outside
`GENERATED_DIR`. Keep this state with the checkout until teardown. It contains
no passwords or signed download URLs. Missing state, changed worker inventory,
foreign registrations, unexpected hosts, or an existing cluster without this
ownership record cause an error rather than automatic adoption. Switching the
provisioning mode is not an in-place migration or expansion operation.

```bash
make worker-status
make verify-workers
# Evacuate workloads using the existing operational workflow before removal.
make delete-worker WORKER_NAME=worker-01
make clean-all
```

Status reports Assisted Installer registration and the corresponding node;
it does not use BMH provisioning status. Removal accepts a configured physical worker
name, powers it off using the existing IPMI helper, clears owned media, and
deletes its node and installer registration. It leaves the installed disk
contents intact. Reprovisioning and subsequent expansion are separate actions.
After removal, the initial-install runner will not silently reinstall the
missing worker. `clean-all` clears owned media before deleting installer state
and honors the existing `POWER_OFF_WORKERS` policy and VM-deletion failure
behavior. If media or boot overrides have changed ownership, cleanup fails
without ejecting them; resolve the conflict before continuing teardown.

Known registration ownership is checked across the current Assisted Installer
account. If `KUBECONFIG` exists, BMH ownership must also be inspectable there.
Machines managed by a different cluster/account must be explicitly released
by that deployment's operator before discovery boot; this tool cannot inventory
unconfigured remote clusters.

Generate configuration through Make and use the repository's existing
environment loader and `.env` format. Do not source the generated file as a
shell script or hand-edit it.

### Validation status and troubleshooting

The implementation was checked against `aicli` **99.0.202609021026** and
`assisted-service-client` **2.55.0.post133** schemas. Disposable offline fixtures
checked installation, reruns, host/disk gates, media ownership, environment
generation, static-VM separation, default DPF orchestration, and credential/file
handling. Later simplifications were checked with old/new behavior comparisons
and a loopback HTTPS Redfish fixture using curl. These development fixtures are
not included in the repository.

A live lab installation completed on **2026-11-01** with:

- OpenShift **4.20.44**, three x86_64 control-plane VMs on local libvirt, and two
  regular Dell PowerEdge R760xa workers. VM and worker addressing used DHCP;
  the configured MTU was **9000**.
- `aicli` **99.0.202609021026**, `assisted-service-client`
  **2.55.0.post149**, and Dell iDRAC firmware **7.20.80.50** and **7.30.30.51**.
  Both workers explicitly selected System VirtualMedia slot `1`.
- All five expected hosts installed with their configured hostnames and roles,
  all five nodes reached Ready, and all 34 cluster operators were healthy.
  Both owned discovery images were ejected and their ownership records cleared.
- The operator measured **47m23.212s** for `make create-base-cluster`, excluding
  the preceding cleanup. The previous
  [OpenShift 4.19 CI deployment](https://prow.ci.openshift.org/view/gs/test-platform-results-public/logs/periodic-ci-rh-ecosystem-edge-nvidia-ci-main-nno-4.19-nno-e2e/2116326895371948032)
  took **77m59s** for base-cluster creation: an observed reduction of about
  **30m36s (39%)**. The OpenShift versions differ, so this is an indicative
  comparison rather than a controlled same-version benchmark.

The lab run used an earlier revision; the subsequent review fixes and
simplifications have only been checked locally. Broader hardware qualification
remains outstanding. This lab run does not cover signed-image
expiry, all asynchronous Redfish task variants, subsequent installed-disk
reboots, normal and jumbo MTU persistence in installed RHCOS and OVN, static
control-plane DNS/routes, remote libvirt, or every interruption/rerun path.
Existing NNO BMO and DPF hardware regressions also remain unrun.

Missing hosts are reported with name and MAC; role/disk/readiness failures show
the affected host and installer validation state. Use the pinned IDs in
`.assisted-day1/` to inspect the intended cluster, rather than choosing a
same-name record. Authentication/request failures deliberately omit response
bodies and signed URLs. Diagnose BMC errors through its task/service logs and
check its independent ISO-server trust and connectivity. The runner never
resets a failed installer cluster or erases disks as a recovery action.

Installer interfaces were verified against the
[Assisted Service API schema](https://github.com/openshift/assisted-service/blob/master/swagger.yaml)
and the installed `aicli` source. Red Hat documents the
[signed discovery-image endpoint](https://docs.redhat.com/en/documentation/openshift_container_platform/4.15/html/nodes/worker-nodes-for-single-node-openshift-clusters),
whose URL can have no `.iso` suffix and must retain its query parameters.
