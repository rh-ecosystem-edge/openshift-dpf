# DPF E2E Test Coverage

**Source**: DPF QA Test Plan (96 TCs total)  
**Pre-GA scope**: Urgent + Very High + High priority only  
**Status**: ✅ Implemented | ⏳ Pending | ❌ Dropped | 🔲 Out of scope (Medium/Low, post-GA)

---

## Section 1: DPF Installation Validation

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-INST-001 | 14390, 14179, 14180 | Urgent | ✅ Implemented | `installation/installation_test.go` |
| TC-INST-002 | — | Urgent | ✅ Implemented | `installation/installation_test.go` |
| TC-INST-003 | — | Urgent | ✅ Implemented | `installation/installation_test.go` |
| TC-INST-004 | 143XX | Urgent | ✅ Implemented | `installation/installation_test.go` |

## Section 2: Network Validation

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-NET-001 | 14178 | Urgent | ✅ Implemented | `networking/connectivity_test.go` |
| TC-NET-002 | 14257 | Low | 🔲 Out of scope | `networking/nad_test.go` (stub) |
| TC-NET-003 | 142XX | High | ✅ Implemented | `networking/connectivity_test.go` |
| TC-NET-004 | 142XX | High | ✅ Implemented | `networking/connectivity_test.go` |

## Section 3: DPUDeployment Lifecycle

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-DPUD-001 | 14161 | Urgent | ✅ Implemented | `dpudeployment/lifecycle_test.go` |
| TC-DPUD-002 | 14139 | Urgent | ✅ Implemented | `dpudeployment/lifecycle_test.go` |
| TC-DPUD-003 | 14149 | Very High | ✅ Implemented | `dpudeployment/lifecycle_test.go` |
| TC-DPUD-004 | 14153 | Very High | ✅ Implemented | `dpudeployment/lifecycle_test.go` |
| TC-DPUD-005 | 14129 | High | ✅ Implemented | `dpudeployment/lifecycle_test.go` |
| TC-DPUD-006 | 141XX | High | ✅ Implemented | `dpudeployment/lifecycle_test.go` |

## Section 4: DPUService Operations

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-SVC-001 | 14172 | Very High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-002 | 14175 | Very High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-003 | 14192 | High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-004 | 14134 | Medium | 🔲 Out of scope | — |
| TC-SVC-005 | 14135 | Medium | 🔲 Out of scope | — |
| TC-SVC-006 | 14336 | High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-007 | 143XX | High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-008 | 143XX | High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-009 | 143XX | High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-010 | 143XX | High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-011 | 143XX | High | ✅ Implemented | `dpuservice/operations_test.go` |
| TC-SVC-012 | 143XX | High | ✅ Implemented | `dpuservice/operations_test.go` |

## Section 5: DPUService Upgrades

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-SVCUPG-001 | 14457 | High | ✅ Implemented | `dpuservice/upgrades_test.go` |
| TC-SVCUPG-002 | 14456 | Very High | ✅ Implemented | `dpuservice/upgrades_test.go` |
| TC-SVCUPG-003 | 14503 | High | ✅ Implemented | `dpuservice/upgrades_test.go` |
| TC-SVCUPG-004 | 14607, 14608 | High | ✅ Implemented | `dpuservice/upgrades_test.go` |
| TC-SVCUPG-005 | 14592 | Very High | ✅ Implemented | `dpuservice/upgrades_test.go` |
| TC-SVCUPG-006 | 14590 | High | ✅ Implemented | `dpuservice/upgrades_test.go` |
| TC-SVCUPG-007 | 14574 | Medium | 🔲 Out of scope | — |

## Section 6: DPF Release Upgrade

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-UPG-001 | 14477 | Low | 🔲 Out of scope | — |
| TC-UPG-002 | 14499 | Urgent | ✅ Implemented | `upgrade/release_upgrade_test.go` |
| TC-UPG-003 | 14484 | High | ✅ Implemented | `upgrade/release_upgrade_test.go` |
| TC-UPG-004 | 14616, 14324 | Medium | 🔲 Out of scope | — |

## Section 7: DPFOperatorConfig

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-OPCFG-001 | 14510 | Medium | 🔲 Out of scope | `operatorconfig/dpfoperatorconfig_test.go` (stub) |
| TC-OPCFG-002 | 14509 | Medium | 🔲 Out of scope | `operatorconfig/dpfoperatorconfig_test.go` (stub) |
| TC-OPCFG-003 | — | — | 🔲 Out of scope | — |

## Section 8: MTU Configuration

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-MTU-001 | 14459 | High | ✅ Implemented | `mtu/mtu_test.go` |
| TC-MTU-002 | 14613 | Medium | 🔲 Out of scope | — |
| TC-MTU-003 | 14481 | High | ✅ Implemented | `mtu/mtu_test.go` |
| TC-MTU-004 | 14497 | Low | 🔲 Out of scope | — |
| TC-MTU-005 | 14480 | Medium | 🔲 Out of scope | `mtu/mtu_test.go` (partial) |

## Section 9: NodeEffect

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-NE-001 | 14439 | Low | ❌ Dropped | `nodeeffect/nodeeffect_test.go` |
| TC-NE-002 | 14438 | Low | ❌ Dropped | `nodeeffect/nodeeffect_test.go` |

## Section 10: Critical DPUServices Label

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-CRIT-001 | 14368 | Very High | ✅ Implemented | `criticalservices/critical_test.go` |
| TC-CRIT-002 | 14370 | Very High | ✅ Implemented | `criticalservices/critical_test.go` |
| TC-CRIT-003 | 14369 | High | ✅ Implemented | `criticalservices/critical_test.go` |
| TC-CRIT-004 | 14374 | Medium | 🔲 Out of scope | — |
| TC-CRIT-005 | 14373 | Medium | 🔲 Out of scope | — |
| TC-CRIT-006 | 14372 | High | ✅ Implemented | `criticalservices/critical_test.go` |

## Section 11: Parallel Provisioning

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-PAR-001 | 14514, 14515 | Low | ❌ Dropped | — |
| TC-PAR-002 | 14517 | High | ✅ Implemented | `parallel/parallel_test.go` |
| TC-PAR-003 | 14518 | High | ✅ Implemented | `parallel/parallel_test.go` |
| TC-PAR-004 | 14329 | Low | ❌ Dropped | — |

## Section 12: DPUDeployment Service Dependencies (all Dropped)

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-DEP-001 | 14343 | Low | ❌ Dropped | `dependencies/deps_test.go` |
| TC-DEP-002 | 14334 | Low | ❌ Dropped | `dependencies/deps_test.go` |
| TC-DEP-003 | 14349 | Low | ❌ Dropped | `dependencies/deps_test.go` |
| TC-DEP-004 | 14348 | Low | ❌ Dropped | `dependencies/deps_test.go` |
| TC-DEP-005 | 14335 | Low | ❌ Dropped | `dependencies/deps_test.go` |
| TC-DEP-006 | 14333, 14332 | Low | ❌ Dropped | `dependencies/deps_test.go` |

## Section 13: Resiliency — Host Reboot/Power

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-RES-001 | 14639 | Urgent | ✅ Implemented | `resiliency/host_reboot_test.go` |
| TC-RES-002 | 14640 | High | ✅ Implemented | `resiliency/host_reboot_test.go` |
| TC-RES-003 | 14169 | Urgent | ✅ Implemented | `resiliency/host_reboot_test.go` |
| TC-RES-004 | 14468 | Very High | ✅ Implemented | `resiliency/host_reboot_test.go` |
| TC-RES-005 | 14160 | Urgent | ✅ Implemented | `resiliency/host_reboot_test.go` |

## Section 14: Resiliency — DPU Operations

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-RES-006 | 14164 | Very High | ✅ Implemented | `resiliency/dpu_ops_test.go` |
| TC-RES-007 | 14131 | High | ✅ Implemented | `resiliency/dpu_ops_test.go` |
| TC-RES-008 | 14202 | Urgent | ✅ Implemented | `resiliency/dpu_ops_test.go` |
| TC-RES-009 | 14464 | Very High | ✅ Implemented | `resiliency/dpu_ops_test.go` |
| TC-RES-010 | 14620 | High | ✅ Implemented | `resiliency/dpu_ops_test.go` |

## Section 15: Resiliency — Cluster Operations

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-RES-011 | 14152 | Very High | ✅ Implemented | `resiliency/cluster_ops_test.go` |
| TC-RES-012 | 14150 | Low | 🔲 Out of scope | — |
| TC-RES-013 | 14137 | High | ✅ Implemented | `resiliency/cluster_ops_test.go` |
| TC-RES-014 | 14151 | Very High | ✅ Implemented | `resiliency/cluster_ops_test.go` |
| TC-RES-015 | 14197 | Very High | ✅ Implemented | `resiliency/cluster_ops_test.go` |
| TC-RES-016 | 14186 | High | ✅ Implemented | `resiliency/cluster_ops_test.go` |
| TC-RES-017 | 141XX | High | ✅ Implemented | `resiliency/cluster_ops_test.go` |

## Section 16: Uninstall

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-UNINST-001 | 14127 | Very High | ✅ Implemented | `uninstall/uninstall_test.go` |
| TC-UNINST-002 | 14141 | High | ✅ Implemented | `uninstall/uninstall_test.go` |

## Section 17: Stability and Robustness

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-STAB-001 | 14162 | Very High | ✅ Implemented | `stability/stability_test.go` |
| TC-STAB-002 | 14136 | High | ✅ Implemented | `stability/stability_test.go` |
| TC-STAB-003 | 14195 | High | ✅ Implemented | `stability/stability_test.go` |
| TC-STAB-004 | 14157 | High | ✅ Implemented | `stability/stability_test.go` |
| TC-STAB-005 | 14133 | High | ✅ Implemented | `stability/stability_test.go` |
| TC-STAB-006 | 14154 | Low | 🔲 Out of scope | — |

## Section 18: BFB

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-BFB-001 | 14XXX | High | ✅ Implemented | `bfb/bfb_test.go` |
| TC-BFB-002 | 14XXX | High | ✅ Implemented | `bfb/bfb_test.go` |
| TC-BFB-003 | 14XXX | High | ✅ Implemented | `bfb/bfb_test.go` |
| TC-BFB-004 | 14XXX | High | ✅ Implemented | `bfb/bfb_test.go` |

## Section 19: Log Collection

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-LOG-001 | 14132 | High | ✅ Implemented | `logcollection/log_test.go` |
| TC-LOG-002 | 141XX | High | ✅ Implemented | `logcollection/log_test.go` |
| TC-LOG-003 | 141XX | High | ✅ Implemented | `logcollection/log_test.go` |

## Section 20: OCP Conformance

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-CONF-001 | 141XX | High | ✅ Implemented | `conformance/conformance_test.go` |

## Section 21: Kubevirt

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-VIRT-001 | 141XX | High | ✅ Implemented | `kubevirt/kubevirt_test.go` |

## Section 22: DPF HCP Provisioner

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-HCP-001 | — | High | ✅ Implemented | `hcpprovisioner/hcp_test.go` |

## Section 23: Kata Containers

| TC | ALM | Priority | Status | Go file |
|----|-----|----------|--------|---------|
| TC-KATA-001 | — | Low | 🔲 Out of scope | — |

---

## Summary

| Priority | Total | Implemented | Pending | Dropped | Out of scope |
|----------|-------|-------------|---------|---------|--------------|
| Urgent | 10 | 10 | 0 | 0 | 0 |
| Very High | 13 | 13 | 0 | 0 | 0 |
| High | 40 | 40 | 0 | 0 | 0 |
| Medium | 8 | 0 | 0 | 0 | 8 |
| Low | 11 | 0 | 0 | 9 | 2 |
| **Total** | **96** | **63** | **0** | **9** | **24** |

**Pre-GA gate**: All Urgent + Very High + High must pass = 63 tests — all 63 implemented.

### Status Legend
- ✅ **Implemented** — Go+Ginkgo test exists, runs on a deployed cluster
- ⏳ **Pending** — High/Urgent priority, not yet implemented
- ❌ **Dropped** — Explicitly excluded from GA scope (Low priority, test plan decision)
- 🔲 **Out of scope** — Medium/Low priority, targeted for post-GA implementation
