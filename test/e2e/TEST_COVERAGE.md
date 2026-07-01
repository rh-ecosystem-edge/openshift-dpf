# DPF E2E Test Coverage

**Source**: DPF QA Test Plan (96 TCs total)  
**Pre-GA scope**: Urgent + Very High + High priority only  
**Status**: ✅ Implemented | ⏳ Pending | ❌ Dropped | 🔲 Out of scope (Medium/Low, post-GA)

> **This PR** establishes the Go+Ginkgo e2e framework and implements the BFB section (TC-BFB-001..004).
> Remaining sections will be added in follow-up PRs, one section per PR.

---

## Section 18: BFB (BlueField Boot Image)

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-BFB-001 | 14XXX | High | ✅ Implemented | `bfb/bfb_test.go` |
| TC-BFB-002 | 14XXX | High | ✅ Implemented | `bfb/bfb_test.go` |
| TC-BFB-003 | 14XXX | High | ✅ Implemented | `bfb/bfb_test.go` |
| TC-BFB-004 | 14XXX | High | ✅ Implemented | `bfb/bfb_test.go` |

### TC-BFB-001 — SecureBoot
- Labels: `bfb`, `requires-ssh`
- First `It` skips (SecureBoot BFB images not yet GA)
- If SSH configured: SSH to hypervisor → `mlxconfig query SECURE_BOOT_ENABLE` → assert enabled

### TC-BFB-002 — SRIOV disabled provisioning
- Labels: `bfb`, `requires-full-provisioning`
- Requires env with DPF operator installed but **no DPUs provisioned yet**
- Creates BFB CR + DPUFlavor (SRIOV_EN=0, NUM_OF_VFS=0) + DPUDeployment
- Waits for BFB Ready → DPUDeployment Ready → all DPUNodes Ready
- If SSH configured: verifies mlxconfig shows SRIOV_EN=0 on hardware
- Run with: `BFB_URL=oci://... go test ./test/e2e/bfb/ --ginkgo.label-filter="requires-full-provisioning"`

### TC-BFB-003 — RHCOS 4.22.X os-layer
- Labels: `bfb`
- Checks BFB URL contains rhcos/coreos/redhat
- If SSH configured: SSH through hypervisor port 2222 to DPU → `/etc/os-release` → assert RHCOS 4.22

### TC-BFB-004 — Red Hat OCI os-layer repository
- Labels: `bfb`
- Checks BFB URL references `registry.redhat.io`, `quay.io/redhat`, or `registry.access.redhat.com`
- Checks BFB Ready condition is True

---

## All Other Sections — Pending (future PRs)

| Section | TCs | Priority | Status |
|---------|-----|----------|--------|
| 1: Installation | TC-INST-001..004 | Urgent | ⏳ Pending |
| 2: Network | TC-NET-001,003,004 | Urgent/High | ⏳ Pending |
| 3: DPUDeployment | TC-DPUD-001..006 | Urgent/High | ⏳ Pending |
| 4: DPUService Ops | TC-SVC-001..012 | Very High/High | ⏳ Pending |
| 5: DPUService Upgrades | TC-SVCUPG-001..006 | Very High/High | ⏳ Pending |
| 6: Release Upgrade | TC-UPG-002,003 | Urgent/High | ⏳ Pending |
| 7: DPFOperatorConfig | TC-OPCFG-001,002 | Medium | 🔲 Out of scope |
| 8: MTU | TC-MTU-001,003 | High | ⏳ Pending |
| 9: NodeEffect | TC-NE-001,002 | Low | ❌ Dropped |
| 10: Critical Services | TC-CRIT-001..003,006 | Very High/High | ⏳ Pending |
| 11: Parallel | TC-PAR-002,003 | High | ⏳ Pending |
| 12: Dependencies | TC-DEP-001..006 | Low | ❌ Dropped |
| 13: Resiliency Host | TC-RES-001..005 | Urgent/High | ⏳ Pending |
| 14: Resiliency DPU | TC-RES-006..010 | Very High/High | ⏳ Pending |
| 15: Resiliency Cluster | TC-RES-011..017 | Very High/High | ⏳ Pending |
| 16: Uninstall | TC-UNINST-001,002 | Very High/High | ⏳ Pending |
| 17: Stability | TC-STAB-001..005 | Very High/High | ⏳ Pending |
| 19: Log Collection | TC-LOG-001..003 | High | ⏳ Pending |
| 20: OCP Conformance | TC-CONF-001 | High | ⏳ Pending |
| 21: KubeVirt | TC-VIRT-001 | High | ⏳ Pending |
| 22: HCP Provisioner | TC-HCP-001 | High | ⏳ Pending |
| 23: Kata Containers | TC-KATA-001 | Low | 🔲 Out of scope |

---

## Running BFB Tests

```bash
# Against a deployed cluster (TC-BFB-001, 003, 004):
KUBECONFIG=/path/to/kubeconfig go test ./test/e2e/bfb/ \
  --ginkgo.label-filter="bfb" -timeout 60m

# Full provisioning test (TC-BFB-002) — cluster must have no DPUs yet:
KUBECONFIG=/path/to/kubeconfig BFB_URL=oci://registry.redhat.io/... \
  go test ./test/e2e/bfb/ \
  --ginkgo.label-filter="requires-full-provisioning" -timeout 180m

# SSH-based assertions (all BFB tests):
KUBECONFIG=... SSH_PRIVATE_KEY_PATH=/path/to/key HYPERVISOR_HOST=10.x.x.x \
  go test ./test/e2e/bfb/ --ginkgo.label-filter="bfb" -timeout 60m
```

## Status Legend
- ✅ **Implemented** — Go+Ginkgo test exists, runs on a deployed cluster
- ⏳ **Pending** — Not yet implemented (planned for a follow-up PR)
- ❌ **Dropped** — Explicitly excluded from GA scope (Low priority)
- 🔲 **Out of scope** — Medium/Low priority, targeted for post-GA
