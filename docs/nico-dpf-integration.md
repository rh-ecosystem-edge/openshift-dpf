# DPF Zero Trust and NICo integration comparison

This report defines the ownership boundary for running NVIDIA Infra Controller (NICo) with the OpenShift DPF Zero Trust automation. It is written for the `feat/nico-zero-trust-integration` branch, based on the latest `origin/main` after PR 431 was merged.

## Decision

Use the latest `origin/main` as the base and enable the integration with `NICO_ENABLED=true`. The default remains the existing standalone DPF flow (`NICO_ENABLED=false`). The two flows must not manage the same DPUDeployment or DPU inventory at the same time.

DPF automation owns the DPF platform and hosted-cluster prerequisites. NICo owns the DPU inventory and the DPF workload objects it generates. DPF reconciles the resulting DPU and DPUService resources after NICo creates them.

## What the current standalone DPF automation does

`make all-zt` currently performs the following sequence:

1. Installs the OpenShift prerequisites, DPF operator, DPF CRDs, DPF operator configuration, BFB registry configuration, DPUCluster, and HCP provisioner.
2. Creates DPU inventory through Zero Trust discovery or static `DPUDevice` and `DPUNode` manifests.
3. Creates the BFB, DPUFlavor, and `DPUDeployment` named `dpudeployment`.
4. Creates the Zero Trust HBN DPUServiceTemplate, service interfaces, IPAM, NAD, and service-chain configuration.
5. Creates the hosted cluster and applies the hosted-cluster authorization needed by DPF services.
6. Uses DPF controllers to provision each DPU and reconcile the DPU services.

This is the supported standalone behavior and remains unchanged when `NICO_ENABLED=false`.

## What current NICo does

With `[dpf].enabled=true`, NICo's carbide API initializes DPF objects for each NICo deployment configuration. Its DPF SDK currently creates or applies the BFB, DPUFlavor, DPUService templates/configurations, interfaces, NADs, service chains, and `DPUDeployment`. The apply is server-side and force-enabled, so an existing object with the same name can be modified by NICo.

NICo also registers the DPU host/DPU node used by its deployment workflow. The current NICo chart does not provide a read-only “adopt this existing DPUDeployment” switch. `--skip-dpf` skips installation of the DPF platform during NICo setup; it does not make NICo read-only for DPF resources. Therefore, installing standalone DPF resources first and then allowing NICo to use the same names creates two writers.

NICo already supports a Zero Trust BF3 flavor and accepts a configurable BFB URL. The generated NICo flavor is not guaranteed to match every local DPF custom flavor value, so the BFB URL, flavor settings, service images, and service configuration must be selected in the NICo configuration when NICo owns those resources.

## Proposed ownership after this PR

| Resource or action | Standalone DPF (`NICO_ENABLED=false`) | NICo integration (`NICO_ENABLED=true`) | Owner in NICo mode |
|---|---|---|---|
| DPF operator, CRDs, NFD, cert-manager, Argo, maintenance prerequisites | Created | Created | DPF automation |
| `DPFOperatorConfig`, BFB registry settings, DPF pull secrets | Created | Created | DPF automation; NICo consumes the platform configuration |
| BMC credential secret | Created from the DPF environment | Created from the DPF environment | DPF automation, one shared secret; NICo must reuse it |
| `DPUCluster` and HCP operator | Created | Created | DPF automation |
| DPU discovery, static `DPUDevice`, static `DPUNode` | Created | Skipped | NICo onboarding/inventory |
| BFB and `DPUFlavor` | Created by DPF post-install | Skipped | NICo |
| `DPUDeployment` | Created as `dpudeployment` | Skipped; HCP reference is configurable | NICo |
| DPUService templates, configs, interfaces, IPAM, NADs, service chains | Created by DPF post-install | Skipped | NICo |
| DPU/DPUService reconciliation | DPF controllers | DPF controllers | DPF |
| Hosted cluster creation | Performed during DPF deployment | Deferred until the NICo `DPUDeployment` exists | DPF HCP provisioner |
| Hosted-cluster DPF authorization | Applied by DPF post-install | Applied after the hosted cluster is ready | DPF automation |
| DPU scale-in/scale-out helpers | Available | Rejected to avoid changing NICo-owned inventory | NICo |
| DPU upgrade helper | Uses the HCP deployment reference | Must be run only after NICo owns the referenced deployment | Coordinated operation |

The DPF automation still configures the DPF platform and HCP operator in NICo mode. It deliberately does not create resources that NICo will force-apply.

## Changes in this PR

1. Add `NICO_ENABLED` (default `false`) and `NICO_DPU_DEPLOYMENT_NAME` (default `dpudeployment`) to the environment contract.
2. Validate the flag and Kubernetes deployment name. NICo mode currently requires `DPF_DEPLOYMENT_MODE=zero-trust`.
3. Skip static/scanning DPF inventory and scripted DPU reboot resources when NICo mode is enabled.
4. Skip DPF-owned Zero Trust BFB, flavor, deployment, and service manifests when NICo mode is enabled.
5. Skip hosted-cluster creation during `deploy-dpf` in NICo mode. This prevents the HCP provisioner from waiting for a DPUDeployment that NICo has not created yet.
6. Replace the hard-coded HCP `dpuDeploymentRef.name` with `NICO_DPU_DEPLOYMENT_NAME`. The default preserves existing standalone behavior; NICo users set it to the NICo deployment name (for example `nico-deployment-v2`).
7. Guard DPF Zero Trust scale helpers and HBN update helpers so they cannot mutate NICo-owned resources.
8. Keep the hosted-cluster SCC/RBAC authorization path available after NICo and HCP are ready.

No NICo source code is changed by this PR. NICo must be installed/configured after the DPF platform step, using its external-DPF/`--skip-dpf` installation path and `[dpf].enabled=true` so that it creates the workload resources against the already-installed DPF operator.

## Deployment sequence with NICo mode

The intended sequence is:

1. Prepare the DPF environment with `DPF_DEPLOYMENT_MODE=zero-trust`, `NICO_ENABLED=true`, and a deployment name that matches the NICo configuration.
2. Run the DPF platform portion (`make all-zt`, or the equivalent existing targets). It installs DPF and HCP prerequisites, creates the DPF configuration and BFB registry settings, and stops before hosted-cluster creation.
3. Install NICo with the external DPF/`--skip-dpf` option. Enable its DPF integration, set the CoreOS BlueField BFB URL, configure the NICo Zero Trust services/images, and point its DPU deployment name at `NICO_DPU_DEPLOYMENT_NAME`.
4. Let NICo register the DPU host/inventory and create the BFB, flavor, service resources, and DPUDeployment. DPF controllers then provision the DPU and reconcile the services.
5. Run `make deploy-hosted-cluster` after the NICo DPUDeployment exists. The HCP provisioner uses the generated `dpuDeploymentRef` and creates the hosted cluster.
6. Run `make deploy-zt-dpu-services` after the hosted cluster API is ready. In NICo mode this applies the DPF hosted-cluster authorization and does not recreate NICo's service resources.

For a deployment name of `nico-deployment-v2`, the relevant environment is:

```bash
DPF_DEPLOYMENT_MODE=zero-trust
NICO_ENABLED=true
NICO_DPU_DEPLOYMENT_NAME=nico-deployment-v2
```

The DPF platform still needs the BFB registry settings, shared DPU BMC password, pull secrets, and other Zero Trust settings. In NICo mode, NICo supplies the DPU serial/BMC inventory and host reboot information, so the DPF static-inventory host BMC fields are not required. NICo additionally needs its own DPU service image/chart configuration and must use a reachable CoreOS BFB URL. A complete DPU test still requires an onboarded, reachable DPU and its host BMC.

## Current lab implications

The lab previously had a DPF-created `dpudeployment` and static DPU inventory, while the live NICo configuration referenced `nico-deployment-v2` and a different BFB/service stack. That is a split ownership state. The DPU failure observed in the lab also included a stale BFB registry endpoint, which is independent of the ownership change and must be corrected before an end-to-end test.

The first safe test of this PR is a render/dry run with `NICO_ENABLED=true`: confirm that no static inventory, DPUDeployment, BFB, flavor, or DPUService workload manifests are applied, and confirm that the generated HCP CR references the NICo deployment name. The end-to-end test then requires NICo to create the deployment and one healthy onboarded DPU.

This is an ownership mode for a fresh or deliberately migrated deployment. `create_dpfhcpprovisioner_cr` remains idempotent and will not rewrite an existing `DPFHCPProvisioner`; on an existing cluster, inspect and intentionally update or recreate that CR before switching its deployment reference.

## Acceptance checks

- `NICO_ENABLED=false` produces the same manifests and execution order as the existing standalone Zero Trust flow.
- `NICO_ENABLED=true` installs the DPF platform but does not apply static DPU inventory or DPF workload resources.
- The generated HCP CR contains the configured NICo deployment name.
- NICo can create its DPF objects without a competing DPF apply from this automation.
- DPF creates the DPU and reconciles NICo's DPU services after the DPU is reachable.
- Hosted-cluster creation succeeds after the NICo deployment exists, and hosted-cluster DPF authorization can be applied afterward.
