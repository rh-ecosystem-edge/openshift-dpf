# DPF 26.11 development stack

This branch selects a source-built DPF release, `v26.11.0-main.d83dfab.jsonfix.3`,
which adds one hostagent change on top of the release merged in #509: when
`dms-cli` cannot read a DPU's operating mode, hostagent reads the same NVConfig
parameter through `mlxconfig`. It is a **BlueField-3 development stack**, not an
official NVIDIA release or a production-ready default update.

## Selected DPF release

`ci/env.defaults` selects:

- `DPF_HELM_REPO_URL=oci://quay.io/itsoiref`
- `DPF_VERSION=v26.11.0-main.d83dfab.jsonfix.3`

All seven DPF runtime images and all three release charts use that same tag. The
chart selects its matching `dpf-system` image, whose packaged
`/etc/dpf-defaults.yaml` selects the matching hostdriver and other components.
`manifests/helm-charts-values/dpf-operator-values.yaml` deliberately has **no
`controllerManager.image` override**. There is no custom component-defaults
ConfigMap mount, checksum patch, or new DPFOperatorConfig image field; in
particular **`spec.dms.image` does not exist**. DMS/hostagent image selection
comes from the operator's release-defaults file.

## Source and differences from upstream

The release is a snapshot of NVIDIA/doca-platform `public-main` at
`d83dfab90dddcb38adf83595264828fc3d7a6bbf` (fetched November 16, 2026), plus
local commits `06c731060` (release preparation), `c48565f8e` (chart image
defaults), `eac8b70ba` (the fallback) and `9b927e548` (`.3` release
preparation). The built tree is `9b927e548b0f6be0d67f341e455e1d4208466135`.
No doca-platform branch was pushed to NVIDIA.

Relative to that upstream baseline there is **exactly one Go-source change**,
in `internal/provisioning/hostagent/util/dpu_mode.go` (with its unit test):

- `dms-cli --target pci/<BDF> --json /nvidia/mode/operating-mode` remains the
  primary reader.
- When dms-cli fails (on DOCA 3.5.0 its `dmspe` resolver cannot resolve the PCI
  target), hostagent falls back to
  `/usr/bin/mlxconfig -d <BDF> -e q INTERNAL_CPU_OFFLOAD_ENGINE` and reads the
  **Current** column. The Default column is what `dmsc` misreports, which is why
  the mode is not read from it.
- A mode outside `dpu`/`nic` is still rejected without falling back, and both
  errors are reported when both readers fail. `SetDPUMode` is unchanged.

Everything else in the diff is the hostdriver installer/helper overlay and its
provenance files, executable ignore entries, release image defaults, and the
subchart/storage chart image tags. The hostname-VIP fix is already upstream in
commit `d6193bcd8a6db96f24dde23154856164d7455a42` and is not reapplied.

### `jsonfix.3` versus `jsonfix.2`

`.2` was merged in #509 with no Go changes, so on nodes where dms-cli's resolver
fails its hostagent errored out instead of reporting the mode, and DPU setup
stalled.
`.3` is the same upstream snapshot with the same hostdriver overlay plus the
fallback above; every other difference is the release tag string. No previous
registry tags were overwritten.

## Published runtime inventory

All repositories below have prefix `quay.io/itsoiref/` and tag
`v26.11.0-main.d83dfab.jsonfix.3`. Digests are immutable audit references; the
effective defaults use the versioned tags.

- `dpf-system` — linux/amd64 and linux/arm64:
  `sha256:97c739dcfa0c6edb4d52c1c5472d47e0a05dce5608cd600591ac8aba3381c900`
- `hostdriver` — linux/amd64:
  `sha256:c80c99987467122ccd64e221b3ece605a5196d34a1ad713d0e98fb4718531365`
- `storage-system` — linux/amd64 and linux/arm64:
  `sha256:badfb90c26829e8cf09e2da8993a0ca950be55e407468f17d9df8569627ab139`
- `storage-host` — linux/amd64 and linux/arm64:
  `sha256:df1b73bafd749bc4171601c8057311cb919aa208ea6aa0c0085aa3249fa4a965`
- `bfb-registry` — linux/amd64 and linux/arm64:
  `sha256:9212177109ff2ab7759659a21609f6fd281539ccfa00cfe234cd44c906bda952`
- `dpf-keepalived` — linux/amd64 and linux/arm64:
  `sha256:090d53caca32e444110efc437003e888d821acde5e5b6a2eaf25ecfcdd75a816`
- `dpf-cni-installer` — linux/arm64:
  `sha256:07843732062765a229a1d1035bc79348952e63df1f80ae62bb41ad71c4175e39`

Hostdriver is amd64-only because the preserved doca-installer is amd64; use x86
host nodes. The multiarch system image supplies management controllers and the
ARM64 DPU-side components; hostdriver carries the amd64 hostagent and ARM64
DPUagent/packages.

Charts use OCI prefix `oci://quay.io/itsoiref/` and version
`v26.11.0-main.d83dfab.jsonfix.3` (leading `v` included):

- `dpf-operator` — OCI digest
  `sha256:6f9095747210c82f3fe0873574c66d5ac1df198946055d99fe6793867c64e8b2`;
  archive SHA256
  `51b8f38489b48a39f51389bae311c6f8ccceafaf4c78b17241217ffce0c7c673`.
- `dpu-networking` — OCI digest
  `sha256:f0b4435e453c37a6e2f9def16b256e70304387c45d6e89f30538d81cf39c41e3`;
  archive SHA256
  `8b8484f6b7d607af85ba23d971b6a865ef64e7bd91eb336d733fa96495d01e86`.
- `dpf-storage` — OCI digest
  `sha256:31baf0f7d9eb1046d2ad29a65f9f2a47cf7d961b9dce5bf8eef81db1a89a940a`;
  archive SHA256
  `a3e930d1ff01900ce5c63972f6456c7afc300f1bae72119aa2fbab08603b327e`.

This is the standard runtime release set (`BUILD_VPC=false`). VPC/private
artifacts, test-helpers, HCP, OVN and HBN images were not rebuilt.

### Hostdriver installer overlay

The selected hostdriver keeps freshly built upstream binaries and the upstream
proprietary DOCA base; only the saved installer and deployment helper are
overlaid, installed mode 0755 and checked in the build:

- doca-installer **2.2.3**, installer source
  `50d51038d618c3b54f7cb366d7cb9b03b14ece45`, SHA256
  `16200f28d105b0409be59fb6d2ad91718bbf2380ee919abaac817f290144ef4d`.
- `/usr/share/doca-installer/dpu-deployment-tool`, SHA256
  `bbb3d184b647cf619551dd2056bc39ba71d1c10c916c51c889d754f7c74da56d`.

The original package installer is preserved at
`/usr/bin/doca-installer.before-jsonfix`. Package inventory reports
doca-installer 2.0.3-1 while the active executable is 2.2.3. `bfb-tool` remains
absent, so deferred bundle repacking is unsupported.

## Unchanged upstream behavior

This branch does not change the HCP defaults that upstream `main` carries:

- HCP operator image is the manually built
  `quay.io/itsoiref/dpf-hcp-provisioner-operator:main-9e868033`, with chart
  `oci://quay.io/redhat-user-workloads/dpu-kit-for-nvidia-operator-tenant/chart`
  and an empty version override (Helm takes the highest semver).
- `DISABLE_NFD` and the rest of the env defaults are unchanged.

The HCP references are moving/hand-built, not immutable pins, and were not
rebuilt or revalidated here.

## Verification of this release

- Seven OCI image builds passed with source packaging enabled; five images are
  amd64+arm64, hostdriver is amd64, cni-installer is arm64.
- All 1,411 tracked Go files under `api/`, `cmd/`, `internal/`, `pkg/`, `test/`
  and `third_party/` match the checkout in each Go-source image/platform.
  Source/version labels, ELF architecture, Go 1.26.10 build metadata, both
  system defaults files, and exact installer/helper bytes/modes/backup were
  checked.
- Network-disabled, read-only, capability-dropped offline smokes passed:
  provisioning help on both system platforms, hostagent help, installer
  version, and helper syntax/help.
- Focused `internal/provisioning/hostagent/util` tests passed on linux/amd64 in
  the pinned Go 1.26.10 image. The same package also builds on macOS; one
  darwin-only test (`RemoveVFFromBridge ... not implemented`) fails identically
  on the pristine upstream base and is unrelated to this change.
- `make generate` (plain and release-args) and full `make lint` passed.
- All first-party chart image defaults use this namespace/tag. Three chart
  lint/offline renders passed, and both trust-mode `DPFOperatorConfig` samples
  passed structural/schema checks (not API-server admission or CEL tests).
- The release BOM check matched all seven images with optional VPC excluded.
- Published image manifests matched the local OCI digests; every platform was
  pulled back by immutable digest and re-checked, and all three charts were
  pulled back byte-identically.

The mlxconfig fallback was exercised on a single BlueField-3 lab node running
DOCA 3.5.0, where dms-cli cannot resolve the PCI target. No hardware,
provisioning or dataplane E2E success is claimed beyond that; both trust modes
still need validation on real hardware.

## Limitations and rollback

- Custom images/charts live in a personal Quay namespace, not supported release
  repositories; pull access/credentials are required.
- Hostdriver requires amd64 host nodes.
- Deferred repacking lacks `bfb-tool`; the zero-trust hostagent installation path
  still needs hardware validation.
- Publication and this PR do not deploy, restart operators, alter API-server
  settings or reprovision DPUs. Those are separate authorized actions.
- Rollback is the merged `#509` selection: set `DPF_VERSION` back to
  `v26.11.0-main.d83dfab.jsonfix.2` and pull the same three charts at that
  version. Its images and charts remain published.
