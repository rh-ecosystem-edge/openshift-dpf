# Opt-in DOCA Argus DPU service

Set `ARGUS_ENABLED=true` to add DOCA Argus to the existing `DPUDeployment`. The default is `false`. `make all` and `make deploy-dpu-services` apply the Argus service template and configuration, then patch the service entry into `DPUDeployment`. `make enable-argus` applies only those Argus resources and patches the entry; it requires an existing `DPUDeployment`.

`make prepare-dpu-files` generates manifests without applying them; the generated `DPUDeployment` is the base manifest and does not include the Argus entry. Use `make deploy-dpu-services` to apply it and add Argus when enabled.

The service uses the `doca-argus` Helm chart, version `1.5.0` by default, with inline configuration and automatic system scanning. No hardware-specific representor ID is configured. Override `ARGUS_CHART_VERSION`, `ARGUS_HELM_REPO_URL`, and `ARGUS_IMAGE` in `.env` as needed.

The chart requests and limits 4 CPU and 10Gi memory per DPU. Include that capacity in each DPU's resource planning.

Argus can run without Kata. Kata always uses PF0, independently of whether Argus is enabled. With `NUM_VFS=46` and the default `KATA_NUM_VFS=8`, Kata uses PF0 VFs 38–45, regular PF0 services use VFs 2–37, and management VF1 remains reserved. These defaults target new clusters; existing pools are not inspected or migrated and must be reconciled manually before deployment.

When `ARGUS_ENABLED=false`, subsequent `DPUDeployment` applies omit the Argus service entry and skip its manifests. Previously applied Argus service template and configuration objects are not explicitly deleted. A default-off fresh deployment removes stale generated Argus manifests and does not install the service.

Older generated `.env` files may still contain the former PF selector, a 24-VF Kata pool, and the PF-specific pool name. Regenerate `.env` or set `KATA_NUM_VFS=8`, `KATA_SRIOV_DP_CONFIG_NAME=bf3-vfs-kata`, and `KATA_INJECTOR_RESOURCE_NAME=openshift.io/bf3-vfs-kata`.
