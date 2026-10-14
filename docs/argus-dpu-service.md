# Opt-in DOCA Argus DPU service

Set `ARGUS_ENABLED=true` to add DOCA Argus to the existing `DPUDeployment`. The default is `false`. `make all` and `make deploy-dpu-services` apply the Argus service template and configuration, then patch the service entry into `DPUDeployment`. `make enable-argus` applies only those Argus resources and patches the entry; it requires an existing `DPUDeployment` and waits until the Argus `DPUService` is Ready before exiting (override `ARGUS_DPUSERVICE_READY_MAX_ATTEMPTS` / `ARGUS_DPUSERVICE_READY_DELAY_SECONDS` to tune the wait). When using `make enable-argus` outside `make all`, also run `make deploy-observability` to deploy the alert receiver and dashboard.

`make prepare-dpu-files` generates manifests without applying them; the generated `DPUDeployment` is the base manifest and does not include the Argus entry. Use `make deploy-dpu-services` to apply it and add Argus when enabled.

The service uses the `doca-argus` Helm chart, version `1.5.0` by default, with inline configuration and automatic system scanning. No hardware-specific representor ID is configured. Override `ARGUS_CHART_VERSION`, `ARGUS_HELM_REPO_URL`, `ARGUS_IMAGE`, and `ARGUS_IMAGE_PULL_SECRET` in `.env` as needed. The container image and pull secret are set on the `DPUServiceTemplate`; the configuration only supplies Argus runtime config.

The chart requests and limits 4 CPU and 10Gi memory per DPU. Include that capacity in each DPU's resource planning. Argus does not require Kata. With Kata enabled, Argus does not inspect VMs on PF1 VFs; if the Kata SR-IOV pool uses PF1, those VMs are not monitored by Argus.

When `ARGUS_ENABLED=false`, subsequent applies omit the Argus service entry from the generated manifest and skip new Argus manifests, but an existing `spec.services.argus` entry can remain on the live `DPUDeployment`. Previously applied Argus service template and configuration objects are not explicitly deleted. Turning the flag off is not an uninstall; remove the service from `DPUDeployment` and delete the Argus CRs manually if needed.

## Alerts in Grafana

Argus writes no local event report and no event stdout, removing the high-volume event log that previously required a cleaner. Its separate service `_dev.log` remains; the service and SDK log levels are set to 40 because at the default level that log grows tens of GB per day. Argus streams events to a Fluent Bit forwarder on the management cluster at `${INGRESS_VIP}:${ARGUS_TELEMETRY_NODE_PORT}`; the NodePort defaults to `30224`. Fluent Bit keeps only `CRITICAL` and `HIGH` alerts and sends them to Loki (72h retention, a 20Gi volume using the deployment's existing `ETCD_STORAGE_CLASS`). The existing `dpf-grafana` instance shows them in the "DOCA Argus Alerts" dashboard, grouped and filtered by the host or workload reported by Argus.

`make deploy-observability` deploys Loki, Fluent Bit, the datasource, and the dashboard (from `manifests/observability/argus/`) when `ARGUS_ENABLED=true`. Loki and Fluent Bit run on control-plane nodes and pull from Docker Hub. `INGRESS_VIP` must be set; rendering the Argus configuration fails without it. If the observability stack is not deployed, the local event report remains disabled and the streamed alerts are lost.
