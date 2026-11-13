# DPF 26.11 development stack

This branch combines the runtime manifest compatibility changes from PR #506,
management API bootstrap authentication for both trust modes, and the custom
DPF/HCP builds used in development. It is **not an official NVIDIA release** or a
production-ready default update. Complete hardware provisioning validation in
both modes before undrafting or merging.

## Selected artifacts

`ci/env.defaults` and `manifests/helm-charts-values/dpf-operator-values.yaml`
select these artifacts:

| Component | Reference |
| --- | --- |
| DPF operator chart | `oci://quay.io/itsoiref/dpf-operator`, version `v26.11.0-main.8c18ca7.jsonfix.1` |
| DPF operator/system image override | `quay.io/itsoiref/dpf-system:v26.11.0-main.81164ef.hostname-jsonfix.2` |
| DMS/hostdriver, selected by embedded defaults | `quay.io/itsoiref/hostdriver:v26.11.0-main.81164ef.hostname-jsonfix.1` |
| HCP operator chart | `oci://quay.io/itsoiref/dpf-hcp-provisioner-chart`, version `0.1.398-main.41d8dcf.no334.1`, OCI digest `sha256:658efd6508d0947472a383c86541ef62f85332a2856fd68337a1106e5e069b03` |
| HCP operator image override | `quay.io/itsoiref/dpf-hcp-provisioner-operator:main-41d8dcf-stack-no334-v1`, linux/amd64 digest `sha256:1427cf6424df594827f4d08d16f2bb2568741165e2f107d382cb35364d5bb5b6` |

### Hostname-only runtime refresh

The selected images use NVIDIA/doca-platform `public-main` baseline
`81164ef7ebf6f0f5603841d88de4e4ec2d3d85df` plus signed-off hostname-only fix
`567c087d621915319473923c5bfee6b7a1333c1d`. This removes the `net.ParseIP`
rejection in `resolveBFBRegistry`: explicit registry LB still wins, IP or
hostname VIP becomes an HTTPS base, and existing downstream logic appends the
NodePort. Empty VIP still errors; host-trusted behavior is unchanged.
**NVIDIA PR #72 and its empty-VIP discovery/fallback are not included.**
API bootstrap kubeconfig, certificate SAN generation and the production address
utility are unchanged from that upstream baseline.

| Selected image | Platforms | Published manifest/index digest |
| --- | --- | --- |
| `dpf-system:v26.11.0-main.81164ef.hostname-jsonfix.2` | linux/amd64, linux/arm64 | `sha256:58b7ce29801309ec454eaf9be04ce96566d2e304a3a9c67eedb5b7ea79c3436f` |
| `hostdriver:v26.11.0-main.81164ef.hostname-jsonfix.1` | linux/amd64 | `sha256:94d51cbbb0e4e3b4bc1d857fe728ca56d8fdf7cf39c013bc281ab574d1b30ae4` |

The hostdriver integration source is
`1469d830ee0bb2f650f4605b6fbdd1b46d84622a`; the multiarch system integration is
`1dbffe57b743b761567b657933ed5e3241696fc2`, whose only additional change is its
self-image default. These signed-off source integrations remain local; no
source branch was pushed to NVIDIA or the doca-platform fork.

The existing chart's supported `controllerManager.image.repository/tag` values
select the multiarch operator image. Its embedded `/etc/dpf-defaults.yaml`
selects the same `.2` system image for management and ARM64 DPU components and
the `.1` hostdriver. The initially published amd64-only system `.1` image remains
available but is **not selected**: SFC and SR-IOV config-init also use
`dpfSystemImage` on ARM64 DPUs. Other runtime images and the networking chart
retain the published `v26.11.0-main.8c18ca7.jsonfix.1` references below.
No charts, HCP, OVN, HBN or ancillary runtime images were rebuilt for this
hostname refresh, and no existing registry tag was overwritten.

This remains the repository's **BlueField-3 development stack**. The retained
8c18ca7 operator chart does not contain the newer upstream BlueField-4
`BMC Force Restart` phase enum/status field. Do not use this chart/image
combination for BF4 PLDM provisioning; that requires a matching updated CRD/chart
and separate validation.

### Retained charts and ancillary runtime release

The earlier seven runtime images and three charts were rebuilt from NVIDIA/doca-platform
`public-main` baseline `8c18ca7f82acfbe6c97c98493ab632ca7c007094`, with local
signed-off integration commit `1d8f7a5c834cec21054c9e444b348b9cfd80b894`.
The source integration is local, not pushed to NVIDIA or the source fork.
This is a snapshot of that baseline, not a moving upstream-head reference.

Unlike the previous custom chart, this source-built release uses the stock
operator chart and `/etc/dpf-defaults.yaml` embedded in `dpf-system`. There is
**no custom component-defaults ConfigMap mount or checksum restart patch**.
The current Helm image override and embedded defaults select the hostname-only
pair above; the other references remain from this earlier release. The table
below preserves the original full-release inventory for audit/rollback, not a
claim that its old system/hostdriver images are still selected. Effective image
defaults use versioned tags; the recorded digests are immutable audit references.
The DMS image is also used by generated hostagent containers. Explicit image
overrides in `DPFOperatorConfig` take precedence; review existing overrides
before deployment.

The original release images use repository prefix `quay.io/itsoiref/` and tag
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
components. No VPC, HCP, OVN or HBN images were rebuilt in that earlier DPF
runtime refresh. The separate HCP CA-only refresh is described below.

### DMS JSON fix

The selected fixed hostdriver's readable tag is:

```text
quay.io/itsoiref/hostdriver:v26.11.0-main.81164ef.hostname-jsonfix.1
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

### Current HCP no-#334 image and CA-trust refresh

The selected Linux/amd64 image is
`quay.io/itsoiref/dpf-hcp-provisioner-operator:main-41d8dcf-stack-no334-v1`,
published manifest digest `sha256:1427cf6424df594827f4d08d16f2bb2568741165e2f107d382cb35364d5bb5b6`.
Its matching chart is `oci://quay.io/itsoiref/dpf-hcp-provisioner-chart`,
version `0.1.398-main.41d8dcf.no334.1`, OCI digest
`sha256:658efd6508d0947472a383c86541ef62f85332a2856fd68337a1106e5e069b03`
and audited archive SHA256
`e502e7067445b02de4cd67cd19a58a15c700b825ae3cb4f69cb3843385d81a9b`.
The chart selects the versioned image tag and deliberately leaves
`image.digest` empty so existing caller repository/tag overrides continue to
work. These digests are immutable audit references, not chart defaults.

The signed-off image source is
`e82406d0e4e579d5c981548fb97cbc744b5b679d`, six commits above HCP
upstream `main` `41d8dcff84604790c7b3f54dd48060bbfb36a8cb`. That baseline
includes merged #338 (DOCA-aware OCP image lookup) and #361 (skip target
ignition files already present). The selected PR changes comprise:

- [#350](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/350),
  [#351](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/351),
  [#348](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/348),
  and draft [#358](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/358),
  stacked in that order, with #358's CA work kept in one commit.
- [#352](https://github.com/rh-ecosystem-edge/dpf-hcp-provisioner-operator/pull/352),
  two commits on the same upstream main.

Rebased source heads are #350 `f12a28f7500236a93c8ea8fcbc91ea63f81dde77`,
#351 `1aeb185574eaa051d2284ce563b93e351827e560`,
#348 `429b0e3b3a0dd709b672184ea71f8b0a6f47466c`,
#358 `db91d04663ecf68fe6ab5844e0b3bafef61da8f1`, and
#352 `5d2298cdad5da19bd6fb24317f2075ab6f79db02`.

PR #334 is explicitly excluded. The image contains no persistent live-journal
archive script, wiring, test or `/var/log/dpu-live-install-journal.tar.gz`
output. Ordinary stdout/journal and kmsg logging remain. The #352 rshim log
reduction preserves boot-log space for completion signals; the installer still
preserves `bfupsignal.sh`, `dpu_agent update-time`, the DPU Config wait,
`sync`, and automatic reboot. No explicit OSInstalled-reporting path or local
hostagent fallback was added.

For DPF newer than 26.4, raw public `CATrustBundle` PEM is base64-templated at
`/etc/pki/ca-trust/source/anchors/dpf-ca.crt` and copied byte-for-byte to that
owned target ignition path when nonblank. Missing/empty/malformed DPF versions
conservatively omit the CA. This CA gate is independent of trust mode and
transport; the BFB registry URL retains its separate Redfish/version gate.
Native RHCOS `coreos-update-ca-trust.service` is expected to extract the trust
without a duplicate installer `ExecStartPre` or custom systemd ordering.
Exact service enablement/order in the target images is **not verified**; TLS
verification is not bypassed.

Verification recorded for this release: focused Go race tests and `make lint`
passed; the published image's Linux/amd64 ELF manager, non-root entrypoint,
source/PR/exclusion labels, embedded installer/updater/units and agent resources
matched the audited source. Restricted offline `--help` passed, and anonymous
pull by immutable digest matched the local manager hash. Go build info records
Go 1.26.10; BuildKit materials were UBI10 micro
`sha256:2ad0f98cb13160c4773c945ef93f88b25831c7f27cd3780d72a7e78b210ea72b`
and UBI10 Go toolset
`sha256:e94c38ff4a099b755af60c73ac87198c613f369eb7f818d45c96fbc3f21047de`.
The chart linted and rendered, including caller tag/digest overrides and both
trust-mode profiles; templates, CRDs and RBAC were unchanged from source.
Anonymous OCI pull matched the published chart digest and audited archive
bytes. No full HCP test suite, hardware, OS trust-service ordering, admission/
CEL, provisioning or dataplane E2E success is claimed.

This PR's HCP refresh changes only `ci/env.defaults` and this document; DPF,
system, hostdriver and ancillary pins are unchanged. Inherited hosted OCP
`4.22.19-multi`, explicit BlueField OCP `4.22.19-4k-doca3.4.2` workaround and
stress defaults from upstream main are retained. The explicit BlueField pin
bypasses automatic image lookup; hardware/DOCA compatibility is unverified.
The custom HCP image is amd64-only, and the retained chart has the known BF4
`BMC Force Restart` schema gap; keep this BF3-scoped PR draft pending hardware
validation in both trust modes.

For historical rollback, the previously selected HCP artifacts remain
available: image `quay.io/itsoiref/dpf-hcp-provisioner-operator:pr334-pr348-pr350-pr352-pr358-a2ea697d-v1`
(`sha256:7ddb3b7de9a936749ea25a9a5a221b59b7e8edbc29f7d7bafebd9d2fcc6d6122`)
and chart `oci://quay.io/itsoiref/dpf-hcp-provisioner-chart` version
`0.1.398-ca.4a977e5.1`
(`sha256:23e8543729dd3b39c8a42b5cefe0ef573d67f7d9097e7988fb1635afb9c69118`).
That prior release **includes #334's journal archive and older ungated CA**; it
is preserved as a coordinated rollback reference, not the current selection.
Do not mix its chart, image or DPF configuration with this release. Publishing
does not deploy the chart or update cached ignition.

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
`DPF_HELM_REPO_URL`, or HCP chart/image override still selects those inputs.
`DPF_VERSION` controls the chart version, **not** the explicit system-image
selection in `manifests/helm-charts-values/dpf-operator-values.yaml`. Changing
charts alone does not remove that override; review it together with embedded
component defaults and any DPFOperatorConfig overrides. These values are passed
directly to Helm, not environment-substituted. Ensure overrides select a
compatible stack: the migrated manifests are not compatible with DPF 26.4. Before using deployment targets,
review the generated configuration, pull secrets, and existing Helm values.

Hostname-only verification:

- Original pair and new multiarch system builds/pushes passed. Pinned registry
  pullbacks verified source/version labels, exact source/default bytes and
  representative ELF architectures. Both system platforms include correctly
  built operator, provisioning, SFC and SR-IOV config-init binaries; offline
  provisioning help passed on both architectures.
- Exact saved JSON installer/helper bytes, executable modes, sidecars and the
  packaged-installer backup were verified in the published hostdriver.
- Focused provisioning, address utility and cloud-init tests and independent
  read-only review passed. Additional release-default and provisioning tests
  passed after the one-line multiarch self-image update.
- Full source `make lint` passed with zero issues in both tool modules and all
  three main linters. The full native macOS `make test` **failed (exit 2)**:
  nine bluefieldsoftware/state Unix-socket listener tests (`bind: invalid argument`),
  seven reboot specs needing Linux `/proc/.../boot_id`, one unsupported netlink
  hostagent-util spec, and eight Linux-only build failures. All failing packages
  and module definitions are unchanged from upstream. No full Linux-suite pass
  or unrelated test repair is claimed.

Earlier full-release verification (8c18ca7; not a claim of all checks rerun for
the hostname-only refresh):

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
  x86 management/host nodes. The selected system image supports both amd64 and
  arm64, including the DPU-side SFC/config-init operands; CNI/other ARM64 operands
  retain their prior published references. These defaults are not suitable for
  an ARM64-only host fleet. The retained CRDs do not support the new BF4 BMC
  restart phase; this remains BF3-scoped as described above.
- Custom images/charts are hosted in a personal Quay namespace, not supported
  release repositories. Registry access and pull credentials remain required.
- The hostdriver lacks `bfb-tool` for deferred bundle repacking.
- No hardware, admission/CEL, provisioning, or dataplane E2E validation was
  performed for this refresh. The saved installer's 76 historical tests were
  not rerun. Remain draft until both trust modes are validated.
- The registry-dependent zero-trust hostagent installation path still requires
  validation; no complete end-to-end success is claimed by this branch.
- Immediate previous head `eee3472a646b4100d7b03f506959c695d06b8b66` retains
  the original full 8c18ca7 release with no system-image override. Its chart and
  image tags remain intact for coordinated rollback.
- Earlier PR head `0bd6c0b82ab1f2b0932bb6ae4f09eb2dc64e4e4b` and artifacts
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
