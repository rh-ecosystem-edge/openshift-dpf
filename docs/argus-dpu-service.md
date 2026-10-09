# Opt-in DOCA Argus DPU service

Set `ARGUS_ENABLED=true` to add DOCA Argus to the existing `DPUDeployment`. The default is `false`. `make all` and `make deploy-dpu-services` render and apply the Argus service when enabled. `make enable-argus` applies only the Argus service template, configuration, and the `DPUDeployment` service entry; it requires an existing `DPUDeployment`.

The service uses the `doca-argus` Helm chart, version `1.5.0` by default, with inline configuration and automatic system scanning. No hardware-specific representor ID is configured. Override `ARGUS_CHART_VERSION`, `ARGUS_HELM_REPO_URL`, and `ARGUS_IMAGE` in `.env` as needed.

The chart requests and limits 4 CPU and 10Gi memory per DPU. Include that capacity in each DPU's resource planning.

When Argus and Kata are both enabled, Kata uses the high-index VF range on PF0 so Argus can inspect those VFs. With `NUM_VFS=46` and `KATA_NUM_VFS=24`, Kata uses PF0 VFs 22–45, regular PF0 services use VFs 2–21, and management VF1 remains reserved. An explicit `KATA_SRIOV_PF_INDEX=1` is rejected for this combination. Existing Kata pools on a different PF or range are rejected before applying manifests; this workflow does not migrate active pools. Run `make deploy-dpu-services` to create the desired pool before using `make enable-argus` on an existing Kata deployment.

Argus is an install gate: turning `ARGUS_ENABLED` back to `false` leaves installed Argus resources and its `DPUDeployment` service entry in place. A default-off fresh deployment removes stale generated Argus manifests and does not install the service.

Older generated `.env` files may still contain `KATA_SRIOV_DP_CONFIG_NAME=bf3-p1-vfs-kata` and the corresponding injector resource. Before a fresh Argus-plus-Kata install, regenerate `.env` or set both to the PF-independent name `bf3-vfs-kata` and `openshift.io/bf3-vfs-kata`.
