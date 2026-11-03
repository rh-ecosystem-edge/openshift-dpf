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
| DPF operator chart | `oci://quay.io/itsoiref/dpf-operator`, version `26.11.0-jsonfix.50d5103.1` |
| DMS/hostdriver, selected by that chart | `quay.io/itsoiref/hostdriver@sha256:5222d699c45cb1108a398cbfb45e8f4f6191116f2257abbb208108a71fa858a9` |
| HCP operator chart | `oci://quay.io/redhat-user-workloads/dpu-kit-for-nvidia-operator-tenant/chart`, version `0.1.398+a2ea697` |
| HCP operator image override | `quay.io/itsoiref/dpf-hcp-provisioner-operator:pr334-pr348-pr350-pr352-a2ea697d-v1` |

The DPF chart's published OCI digest is
`sha256:b087f07a46f987ab974ec3f4a23fd72d75a71426fe7c395645b669f6f98eea2c`.
It mounts a complete component-defaults ConfigMap at `/etc/dpf-defaults.yaml`,
pins the reused DPF images by digest, and restarts the operator when defaults
change. The DMS image is also used by the generated hostagent containers.
Explicit image overrides in `DPFOperatorConfig` take precedence over these
chart defaults; review any existing overrides before deployment.

### DMS JSON fix

The fixed hostdriver's readable tag is:

```text
quay.io/itsoiref/hostdriver:v26.11-dms-cli-fec7f37d8-jsonfix-50d5103-helper-amd64
```

It contains doca-installer **2.2.3**, JSON-fix revision
`50d51038d618c3b54f7cb366d7cb9b03b14ece45`, and the matching executable
`/usr/share/doca-installer/dpu-deployment-tool`.
The upstream DMS mode reader is restored from `fec7f37d8`; this is not the
older mode-reader-revert or BFB-only workaround image.

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

Offline bootstrap-authentication regression tests:

```bash
python3 -m unittest discover -s test/scripts -v
bash -n scripts/dpf.sh
```

The tests mock every `oc` invocation and never source the real `.env`.
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
- The registry-dependent zero-trust hostagent installation path still requires
  validation; no complete end-to-end success is claimed by this branch.
- Preserve previous Helm versions/values and API-server configuration before
  deployment. Roll back as a coordinated stack, not just a DPF version override:
  older DPF releases require their matching manifests. A Helm rollback does not
  revert the kube-apiserver `unsupportedConfigOverrides` setting; restore only
  that setting to its recorded previous value when appropriate, preserving
  unrelated overrides and accounting for any still-dependent DPU agents.
