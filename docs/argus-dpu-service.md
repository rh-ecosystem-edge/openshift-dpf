# Opt-in DOCA Argus DPU service

Set `ARGUS_ENABLED=true` to add DOCA Argus to the existing `DPUDeployment`. The default is `false`. `make all` and `make deploy-dpu-services` render and apply the Argus service when enabled. `make enable-argus` applies only the Argus service template, configuration, and the `DPUDeployment` service entry; it requires an existing `DPUDeployment`.

The service uses the `doca-argus` Helm chart, version `1.5.0` by default, with inline configuration and automatic system scanning. No hardware-specific representor ID is configured. Override `ARGUS_CHART_VERSION`, `ARGUS_HELM_REPO_URL`, and `ARGUS_IMAGE` in `.env` as needed.

The chart requests and limits 4 CPU and 10Gi memory per DPU. Include that capacity in each DPU's resource planning.

Argus can run without Kata. Kata uses PF0 by default, independently of whether Argus is enabled. With `NUM_VFS=46` and the default `KATA_NUM_VFS=8`, Kata uses PF0 VFs 38–45, regular PF0 services use VFs 2–37, and management VF1 remains reserved. A Kata-only deployment can override `KATA_SRIOV_PF_INDEX=1`; PF1 is rejected when both Argus and Kata are enabled. Existing Kata pools on a different PF or range are rejected before applying manifests; this workflow does not migrate active pools.

Argus is an install gate: turning `ARGUS_ENABLED` back to `false` leaves installed Argus resources and its `DPUDeployment` service entry in place. A default-off fresh deployment removes stale generated Argus manifests and does not install the service.

Older generated `.env` files may still contain `KATA_SRIOV_PF_INDEX=auto`, `KATA_NUM_VFS=24`, `KATA_SRIOV_DP_CONFIG_NAME=bf3-p1-vfs-kata`, and the corresponding injector resource. For a new cluster, regenerate `.env` or set PF index `0`, pool size `8`, and both resource names to `bf3-vfs-kata` and `openshift.io/bf3-vfs-kata`.
