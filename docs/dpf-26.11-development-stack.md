# DPF 26.11 development stack

This branch combines the runtime manifest compatibility changes from PR #506,
management API bootstrap authentication for both trust modes, and the custom
DPF/HCP builds used in development. It is **not an official NVIDIA release** or a
production-ready default update. Complete hardware provisioning validation in
both modes before undrafting or merging.

## Selected artifacts

`ci/env.defaults` selects these artifacts unless the user overrides them:

| Component | Reference |
| --- | --- |
| DPF operator chart | `oci://quay.io/itsoiref/dpf-operator`, version `v26.11.0-main.8c18ca7.jsonfix.1` |
| DMS/hostdriver, selected by embedded defaults | `quay.io/itsoiref/hostdriver:v26.11.0-main.8c18ca7.jsonfix.1` |
| HCP operator chart | `oci://quay.io/redhat-user-workloads/dpu-kit-for-nvidia-operator-tenant/chart`, version `0.1.398+a2ea697` |
| HCP operator image override | `quay.io/itsoiref/dpf-hcp-provisioner-operator:pr334-pr348-pr350-pr352-a2ea697d-v1` |

### Fresh runtime release

All seven runtime images and three charts were rebuilt from NVIDIA/doca-platform
`public-main` baseline `8c18ca7f82acfbe6c97c98493ab632ca7c007094`, with local
signed-off integration commit `1d8f7a5c834cec21054c9e444b348b9cfd80b894`.
The source integration is local, not pushed to NVIDIA or the source fork.
This is a snapshot of that baseline, not a moving upstream-head reference.

Unlike the previous custom chart, this source-built release uses the stock
operator chart and `/etc/dpf-defaults.yaml` embedded in the fresh `dpf-system`
image. There is **no custom component-defaults ConfigMap mount or checksum
restart patch**. Embedded defaults and chart image defaults select the new tag,
not the old reused images or digest overrides. The table below records immutable
registry digests for audit; the effective defaults select versioned tags.
The DMS image is also used by generated hostagent containers. Explicit image
overrides in `DPFOperatorConfig` take precedence; review existing overrides
before deployment.

All images use repository prefix `quay.io/itsoiref/` and tag
`v26.11.0-main.8c18ca7.jsonfix.1`:

| Image | Platforms | Published manifest digest |
| --- | --- | --- |
| `hostdriver` | linux/amd64 | `sha256:02d857cede65d16d5591c73e29b222b48e9da7d54e0e3d16a2c15b89a76acc0c` |
| `dpf-system` | linux/amd64, linux/arm64 | `sha256:fd6b213bb8d358c0c1780c3d2f5349c5f5fd45d36a27a4dad7c4a20836e2ee2a` |
| `storage-system` | linux/amd64, linux/arm64 | `sha256:d7ddb7b9fc1e46dd5eb41ce87c755a5323c242d0487f2e75c589549cbd0596b9` |
| `storage-host` | linux/amd64, linux/arm64 | `sha256:c8e0da5a3bc5816c8bc9b1f5ac009c4cc403efe8fa6d0167f619384ee3e6f111` |
| `bfb-registry` | linux/amd64, linux/arm64 | `sha256:a30c99eb9e86f3450761ebdd1bdd3abe52f95c849a8af214f4a49d346aa9225b` |
| `dpf-keepalived` | linux/amd64, linux/arm64 | `sha256:704d9cc02e5bdffdbc5bbaeba8951b95e0823cfccd98f6c5b83ac232a0800442` |
| `dpf-cni-installer` | linux/arm64 | `sha256:deeffbf764a9f28aa2eab5c37d4ae8dc4665b9fc04f158e27590c479c773d20b` |

All charts use OCI prefix `oci://quay.io/itsoiref/` and the same version
`v26.11.0-main.8c18ca7.jsonfix.1` (including the leading `v`):

| Chart | Published OCI digest |
| --- | --- |
| `dpf-operator` | `sha256:46d6d7d44846c86bf5c6d378ed748f23440ea0f6d7fcec51fd25fa2d97f9a5c8` |
| `dpu-networking` | `sha256:6be4da63bea295fc3f2a1c411530dec7513d9c3cb2094f88fcfbc1cb629af618` |
| `dpf-storage` | `sha256:fc07b4885ea4f01a123dd137f18e3e09ffe6c97f1399ef87cb93e44c5bd614cb` |

Publishing the storage/networking charts does not enable their optional
components. No VPC, HCP, OVN or HBN images were rebuilt in this runtime refresh;
the existing HCP selection below is unchanged.

### DMS JSON fix

The fixed hostdriver's readable tag is:

```text
quay.io/itsoiref/hostdriver:v26.11.0-main.8c18ca7.jsonfix.1
```

It contains doca-installer **2.2.3**, JSON-fix revision
`50d51038d618c3b54f7cb366d7cb9b03b14ece45`, and the matching executable
`/usr/share/doca-installer/dpu-deployment-tool`.
The fresh `public-main` runtime already contains the DMS JSON mode reader and
OVN nil guard; no historical mode-reader or controller patches were reapplied.
The exact saved installer and helper were overlaid on the fresh hostdriver,
not rebuilt or substituted:

- Installer SHA256: `16200f28d105b0409be59fb6d2ad91718bbf2380ee919abaac817f290144ef4d`.
- Helper SHA256: `bbb3d184b647cf619551dd2056bc39ba71d1c10c916c51c889d754f7c74da56d`.

The packaged installer 2.0.3 is preserved as
`/usr/bin/doca-installer.before-jsonfix`; the active installer is 2.2.3.
Latest-source hostagent/DPUagent binaries are retained.

### Combined HCP image

The published image digest is
`sha256:19fa9ee7e69744a58360fc81f28f5900ec5a48b9a1400787e3fa39ece06cc41e`.
It is based on upstream `a2ea697d` and includes:

- [#334](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/334): preserve the live installation journal in installed RHCOS.
- [#348](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/348): provide `BFBRegistryURL` only for Redfish installation.
- [#350](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/350): provide bootstrap kubeconfig in all DPU security modes.
- [#352](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/352): keep routine installer logs out of the limited rshim boot-log buffer.

It retains automatic reboot, `bfupsignal.sh`, and `dpu_agent update-time`.
It does **not** include the experimental explicit OSInstalled-reporting path,
the separate local hostagent OSInstalled-promotion fallback, or PR #338's
DOCA-aware OCP image lookup.

## Runtime configuration changes

- Enable CNI installation in both trust modes with the existing RHCOS paths.
- Set `DPFOperatorConfig.spec.deploymentMode` explicitly in both templates.
- Migrate `DPUServiceIPAM.spec.ipv4Network` to `spec.network`.
- Use `interfaceType: patch` with `patch.peerBridge: br-ovn` for the
  host-trusted OVN service interface. The peer bridge must already exist.
- Enable bootstrap-token authentication on the management kube-apiserver
  before installing DPF in **both modes**. This uses OpenShift
  `unsupportedConfigOverrides`, can trigger an API-server rollout, and retains
  the idempotency check and final API health wait. The shared patch is
  `manifests/dpf-installation/kube-apiserver-bootstrap-auth.patch.yaml`.

## Use and validation

Existing `.env` files do not automatically acquire new defaults. Review and
regenerate the configuration from the canonical `ci/` files, preserving any
required environment-specific inputs:

```bash
make generate-env FORCE=true
make validate-env-files
```

Do not hand-edit generated `.env`. A caller-supplied `DPF_VERSION`,
`DPF_HELM_REPO_URL`, or HCP chart/image override still takes precedence. Ensure
those overrides select a compatible stack: the migrated manifests are not
compatible with the previous DPF 26.4 default. Before using deployment targets,
review the generated configuration, pull secrets, and existing Helm values.

Release verification completed before selecting these references:

- Full `make generate` and full `make lint` passed in the source clone.
- All seven images passed remote platform, version/source-label and
  representative ELF checks. The embedded defaults matched the source bytes.
- The project release air-gap BOM check matched all seven runtime images
  (`BUILD_VPC=false`).
- All three charts were packaged, linted/rendered, and audited for 16 first-party
  image defaults. Published charts were pulled back and compared byte-for-byte
  with the audited archives.
- Exact installer/helper offline smokes and local JSON-stream byte fixtures
  passed. These do not exercise the full compiled-installer configuration path.
- The initial ARM64 storage-host package-download timeout was resolved by a
  retry without source changes. No previous registry tags were overwritten.

Offline shell syntax validation:

```bash
bash -n scripts/dpf.sh ci/env.defaults
```
Publishing these changes does not deploy the chart, roll out operators, modify
a cluster, or regenerate cached DPU ignition. A deployment must roll out the
operator and generate fresh ignition/reprovision DPUs to use installer changes.

## Limitations and rollback

- The fixed hostdriver and combined HCP image are **linux/amd64 only**. Use
  x86 management/host nodes; ARM64 DPU-side operands remain separately selected
  by the DPF chart. These defaults are not suitable for an ARM64-only host fleet.
- Custom images/charts are hosted in a personal Quay namespace, not supported
  release repositories. Registry access and pull credentials remain required.
- The hostdriver lacks `bfb-tool` for deferred bundle repacking.
- No hardware, admission/CEL, provisioning, or dataplane E2E validation was
  performed for this refresh. The saved installer's 76 historical tests were
  not rerun. Remain draft until both trust modes are validated.
- The registry-dependent zero-trust hostagent installation path still requires
  validation; no complete end-to-end success is claimed by this branch.
- Previous PR head `0bd6c0b82ab1f2b0932bb6ae4f09eb2dc64e4e4b` and artifacts
  remain available for coordinated rollback: DPF operator chart version
  `26.11.0-jsonfix.50d5103.1`, OCI digest
  `sha256:b087f07a46f987ab974ec3f4a23fd72d75a71426fe7c395645b669f6f98eea2c`,
  and previous hostdriver digest
  `sha256:5222d699c45cb1108a398cbfb45e8f4f6191116f2257abbb208108a71fa858a9`.
  That previous chart used the custom defaults ConfigMap and reused images;
  restore its matching configuration rather than mixing old/new defaults.
- Preserve previous Helm versions/values and API-server configuration before
  deployment. Roll back as a coordinated stack, not just a DPF version override:
  older DPF releases require their matching manifests. A Helm rollback does not
  revert the kube-apiserver `unsupportedConfigOverrides` setting; restore only
  that setting to its recorded previous value when appropriate, preserving
  unrelated overrides and accounting for any still-dependent DPU agents.
