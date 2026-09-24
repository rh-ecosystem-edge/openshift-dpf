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
