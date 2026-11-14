#!/usr/bin/env bash
# zt-tenant-cluster.sh — provision a tenant HostedCluster on physical DPU-host servers (Agent + BMH)
#
# Prerequisites: management cluster, DPU HostedCluster from DPF HCP Provisioner (all-zt),
# MCE with HyperShift + Assisted Service, Metal3 watching all namespaces.
#
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "${SCRIPT_DIR}/utils.sh"
# shellcheck source=scripts/tools.sh
source "${SCRIPT_DIR}/tools.sh"
# shellcheck source=scripts/metallb.sh
source "${SCRIPT_DIR}/metallb.sh"

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
# validate_zt_tenant_configuration() and its helpers live in env.sh, next to the
# ZT_TENANT_* defaults and the other env validators.

# -----------------------------------------------------------------------------
# DPU hosted cluster health (before tenant changes)
# -----------------------------------------------------------------------------

# A Ready DPFHCPProvisioner implies the DPU HostedCluster is Available, so there
# is no separate HostedCluster check here. The shared wait lives in utils.sh
# because post-install.sh uses it too.

_tenant_hc_condition() {
    local ns="$1" name="$2" cond="$3"
    oc get hostedcluster -n "${ns}" "${name}" \
        -o "jsonpath={.status.conditions[?(@.type==\"${cond}\")].status}" 2>/dev/null || true
}

# Both conditions are reconciled by the HyperShift operator. It creates the
# RoleBinding in the agent namespace, but relies on the CLI (or on
# ensure_tenant_capi_provider_role below) to have created the Role it binds.
wait_tenant_hosted_cluster_platform_ready() {
    local ns="${CLUSTERS_NAMESPACE}"
    local name="${ZT_TENANT_CLUSTER_NAME}"
    log [INFO] "Waiting for tenant HostedCluster ${ns}/${name} (PlatformCredentialsFound, ReconciliationSucceeded)..."
    if ! oc wait "hostedcluster/${name}" -n "${ns}" \
        --for=condition=PlatformCredentialsFound \
        --for=condition=ReconciliationSucceeded \
        --timeout=20m; then
        log [ERROR] "Tenant HostedCluster ${name} platform credentials are not ready"
        oc get hostedcluster -n "${ns}" "${name}" -o yaml | tail -n 40 || true
        return 1
    fi
    log [INFO] "Tenant HostedCluster ${name} platform credentials are ready"
}

wait_tenant_hosted_cluster_for_nodepool() {
    local ns="${CLUSTERS_NAMESPACE}"
    local name="${ZT_TENANT_CLUSTER_NAME}"
    log [INFO] "Waiting for tenant HostedCluster ${ns}/${name} Available before NodePool..."
    if ! oc wait "hostedcluster/${name}" -n "${ns}" --for=condition=Available --timeout=20m; then
        log [ERROR] "Tenant HostedCluster ${name} is not Available; cannot create NodePool"
        oc get hostedcluster -n "${ns}" "${name}" -o yaml | tail -n 40 || true
        return 1
    fi
    log [INFO] "Tenant HostedCluster ${name} is ready for NodePool creation"
}

# -----------------------------------------------------------------------------
# MCE / Assisted / Metal3
# -----------------------------------------------------------------------------

# MCE may leave Available briefly while it reconciles a newly enabled component.
_wait_mce_available() {
    local mce_name="$1"
    log [INFO] "Waiting for MultiClusterEngine ${mce_name} to become Available..."
    if ! oc wait "multiclusterengine/${mce_name}" \
        --for=jsonpath='{.status.phase}'=Available --timeout=20m; then
        log [ERROR] "MultiClusterEngine ${mce_name} did not become Available"
        oc get multiclusterengine "${mce_name}" \
            -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" "}{.message}{"\n"}{end}' 2>/dev/null || true
        return 1
    fi
    log [INFO] "MultiClusterEngine ${mce_name} phase=Available"
}

mce_enable_components() {
    local mce_name="$1"
    shift
    local comp cur_json new_json
    cur_json=$(oc get multiclusterengine "${mce_name}" -o json)
    new_json="${cur_json}"
    if ! echo "${new_json}" | jq -e '.spec.overrides.components' >/dev/null 2>&1; then
        new_json=$(echo "${new_json}" | jq '.spec.overrides.components = []')
    fi
    for comp in "$@"; do
        if echo "${new_json}" | jq -e --arg c "${comp}" '.spec.overrides.components[]? | select(.name==$c)' >/dev/null 2>&1; then
            new_json=$(echo "${new_json}" | jq --arg c "${comp}" '(.spec.overrides.components[] | select(.name==$c) | .enabled) = true')
        else
            new_json=$(echo "${new_json}" | jq --arg c "${comp}" '.spec.overrides.components += [{"name": $c, "enabled": true}]')
        fi
    done
    echo "${new_json}" | oc apply -f -
}

# HyperShift already runs the DPU HostedCluster (wait_for_dpfhcp_provisioner_ready),
# so the tenant flow only adds Assisted Installer discovery.
ensure_mce_assisted() {
    local mce_name enabled
    mce_name=$(oc get multiclusterengine -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${mce_name}" ]; then
        log [ERROR] "No MultiClusterEngine CR found; deploy the DPU HostedCluster via MCE first"
        return 1
    fi

    enabled=$(oc get multiclusterengine "${mce_name}" \
        -o jsonpath='{.spec.overrides.components[?(@.name=="assisted-service")].enabled}' 2>/dev/null || true)
    if [ "${enabled}" = "true" ]; then
        log [INFO] "Assisted Service is already enabled on MultiClusterEngine ${mce_name}"
    else
        log [INFO] "Enabling Assisted Service on MultiClusterEngine ${mce_name}"
        mce_enable_components "${mce_name}" assisted-service || return 1
    fi

    _wait_mce_available "${mce_name}" || return 1
    log [INFO] "MCE Assisted stack is ready"
}

ensure_agent_service_config() {
    if oc get agentserviceconfig agent -n multicluster-engine &>/dev/null; then
        log [INFO] "AgentServiceConfig agent already exists; using it"
        return 0
    fi

    log [INFO] "Creating AgentServiceConfig agent (RHCOS ${ZT_TENANT_RHCOS_VERSION}, arch ${ZT_TENANT_RHCOS_OSIMAGE_ARCH})..."
    local out="${ZT_TENANT_GENERATED_DIR}/agentserviceconfig.yaml"
    mkdir -p "${ZT_TENANT_GENERATED_DIR}"

    process_template \
        "${MANIFESTS_DIR}/zt-tenant/agentserviceconfig-template.yaml" \
        "${out}" \
        "<ZT_TENANT_OPENSHIFT_VERSION_MINOR>" "${ZT_TENANT_OPENSHIFT_VERSION_MINOR}" \
        "<ZT_TENANT_RHCOS_VERSION>" "${ZT_TENANT_RHCOS_VERSION}" \
        "<ZT_TENANT_RHCOS_ISO_URL>" "${ZT_TENANT_RHCOS_ISO_URL}" \
        "<ZT_TENANT_RHCOS_ROOTFS_URL>" "${ZT_TENANT_RHCOS_ROOTFS_URL}" \
        "<ZT_TENANT_RHCOS_OSIMAGE_ARCH>" "${ZT_TENANT_RHCOS_OSIMAGE_ARCH}" \
        "<ETCD_STORAGE_CLASS>" "${ETCD_STORAGE_CLASS}"

    apply_manifest "${out}" true
    log [INFO] "Waiting for assisted-service pods after AgentServiceConfig..."
    if ! retry 60 10 bash -c 'oc get pods -n multicluster-engine -l app=assisted-service --no-headers 2>/dev/null | grep -q Running'; then
        log [ERROR] "assisted-service did not become Running; check AgentServiceConfig and storage"
        oc get pods -n multicluster-engine | grep assisted || true
        return 1
    fi
}

_tenant_log_discovery_prereqs() {
    local ns bmh img_url route_host assisted_route
    ns="$(zt_tenant_agent_namespace)"
    route_host=$(oc get route assisted-image-service -n multicluster-engine -o jsonpath='{.spec.host}' 2>/dev/null || true)
    assisted_route="${route_host}"
    [ -n "${assisted_route}" ] || assisted_route="assisted-image-service route missing"
    log [INFO] "Discovery uses PreprovisioningImage (not DataImage). Assisted route: https://${assisted_route}"
    while IFS= read -r bmh; do
        [ -n "${bmh}" ] || continue
        img_url=$(oc get preprovisioningimage -n "${ns}" "${bmh}" -o jsonpath='{.status.imageUrl}' 2>/dev/null || true)
        [ -n "${img_url}" ] || img_url="pending"
        log [INFO] "PreprovisioningImage ${ns}/${bmh} imageUrl: ${img_url}"
    done < <(oc get bmh -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    log [INFO] "iDRAC fetches imageUrl via HTTPS; import ingress CA if virtual media fails (BMH disableCertificateVerification is Redfish-only)."
    log [INFO] "Router CA: oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.ca-bundle\\.crt}' | base64 -d"
}

# The HyperShift Agent platform keeps its BareMetalHosts, InfraEnv and Agents in
# the agent namespace (clusters-tenant), not in openshift-machine-api, so the
# single Metal3 Provisioning deployment must reconcile all namespaces.
ensure_metal3_watch_all_namespaces() {
    local watch
    if ! watch="$(oc get provisioning provisioning-configuration -o jsonpath='{.spec.watchAllNamespaces}' 2>/dev/null)"; then
        log [ERROR] "Provisioning CR provisioning-configuration not found; is Metal3 running on the hub?"
        return 1
    fi
    if [ "${watch}" = "true" ]; then
        log [INFO] "Metal3 already watches all namespaces"
        return 0
    fi
    log [INFO] "Enabling Metal3 watchAllNamespaces for tenant BareMetalHosts..."
    oc patch provisioning provisioning-configuration --type=merge -p '{"spec":{"watchAllNamespaces":true}}' || {
        log [ERROR] "Failed to patch provisioning-configuration watchAllNamespaces"
        return 1
    }
}

# -----------------------------------------------------------------------------
# HostedCluster + NodePool (HyperShift CLI)
# -----------------------------------------------------------------------------

zt_tenant_agent_namespace() {
    echo "${CLUSTERS_NAMESPACE}-${ZT_TENANT_CLUSTER_NAME}"
}

# hypershift CLI can assign KUBECONFIG in-shell to a not-yet-written tenant admin path; restore mgmt for oc.
_restore_mgmt_kubeconfig() {
    if [ -n "${MGMT_KUBECONFIG}" ] && [ -f "${MGMT_KUBECONFIG}" ]; then
        export KUBECONFIG="${MGMT_KUBECONFIG}"
    fi
}

ensure_tenant_namespace() {
    local ns="$1"
    if oc get namespace "${ns}" &>/dev/null; then
        return 0
    fi
    oc create namespace "${ns}"
}

# The Agent-platform CAPI provider needs a Role named capi-provider-role in the
# agent namespace. The hypershift CLI used to emit it; openshift/hypershift#8305
# moved that to newer operators, which create their own per-cluster Role
# (capi-provider-role-<control-plane-namespace>). With a newer CLI against an
# operator that predates that change — the combination MCE gives us — nothing
# creates it and HostedCluster reconciliation fails with:
#   failed to reconcile platform credentials: failed to reconcile Agent
#   RoleBinding: rolebindings.rbac.authorization.k8s.io "capi-provider-role"
#   not found
# Apply the Role ourselves; it is inert for operators that no longer use it.
ensure_tenant_capi_provider_role() {
    local ns="$1" out
    out="${ZT_TENANT_GENERATED_DIR}/capi-provider-role.yaml"
    mkdir -p "${ZT_TENANT_GENERATED_DIR}"
    log [INFO] "Ensuring CAPI provider Role capi-provider-role in ${ns}..."
    process_template \
        "${MANIFESTS_DIR}/zt-tenant/capi-provider-role-template.yaml" \
        "${out}" \
        "<ZT_TENANT_AGENT_NAMESPACE>" "${ns}"
    retry 5 10 apply_manifest "${out}" true
}

# Touch the HostedCluster so an operator stuck in error backoff reconciles now
# instead of waiting for its next resync.
_nudge_tenant_hostedcluster() {
    local ns="$1"
    oc annotate hostedcluster -n "${ns}" "${ZT_TENANT_CLUSTER_NAME}" \
        "openshift-dpf.io/capi-provider-role-heal=$(date +%s)" --overwrite >/dev/null || true
}

create_tenant_pull_secret() {
    local ns="$1"
    ensure_tenant_namespace "${ns}" || return 1
    oc create secret generic "${ZT_TENANT_PULL_SECRET_NAME}" \
        -n "${ns}" \
        --from-file=".dockerconfigjson=${OPENSHIFT_PULL_SECRET}" \
        --type=kubernetes.io/dockerconfigjson \
        --dry-run=client -o yaml | oc apply -f -
}

create_tenant_hostedcluster_skip_nodepool() {
    local ns="${CLUSTERS_NAMESPACE}"
    local agent_ns
    agent_ns="$(zt_tenant_agent_namespace)"
    ensure_hypershift_cli || return 1

    _restore_mgmt_kubeconfig
    if oc get hostedcluster -n "${ns}" "${ZT_TENANT_CLUSTER_NAME}" &>/dev/null; then
        local platform_ok recon_ok strategy
        # Exposure is fixed at creation: spec.services is immutable on the Agent
        # platform, so a NodePort cluster cannot be promoted to MetalLB in place.
        if _tenant_metallb_enabled; then
            strategy="$(_tenant_hc_apiserver_strategy)"
            if [ "${strategy}" != "LoadBalancer" ]; then
                _tenant_apiserver_strategy_error "${strategy}"
                return 1
            fi
        fi
        platform_ok="$(_tenant_hc_condition "${ns}" "${ZT_TENANT_CLUSTER_NAME}" "PlatformCredentialsFound")"
        recon_ok="$(_tenant_hc_condition "${ns}" "${ZT_TENANT_CLUSTER_NAME}" "ReconciliationSucceeded")"
        if [ "${platform_ok}" = "True" ] && [ "${recon_ok}" = "True" ]; then
            log [INFO] "HostedCluster ${ZT_TENANT_CLUSTER_NAME} already exists and reconciled; skipping create"
            return 0
        fi
        if oc get namespace "${agent_ns}" &>/dev/null; then
            # Re-run after an earlier credential failure: heal the missing Agent
            # CAPI provider Role and make the operator retry immediately.
            ensure_tenant_capi_provider_role "${agent_ns}" || return 1
            _nudge_tenant_hostedcluster "${ns}"
            log [INFO] "HostedCluster ${ZT_TENANT_CLUSTER_NAME} already exists; CAPI provider Role ensured in ${agent_ns}; skipping create"
            return 0
        fi
        log [ERROR] "HostedCluster ${ZT_TENANT_CLUSTER_NAME} exists but is not healthy (PlatformCredentialsFound=${platform_ok}, ReconciliationSucceeded=${recon_ok})"
        oc get hostedcluster -n "${ns}" "${ZT_TENANT_CLUSTER_NAME}" -o yaml | tail -n 40 || true
        return 1
    fi

    local ssh_key publishing_strategy="NodePort"
    ssh_key="$(_tenant_ssh_key_path)" || return 1

    # MetalLB exposure: the CLI's LoadBalancer strategy is the bare-metal
    # production shape (APIServer LoadBalancer, OAuth/Konnectivity/Ignition
    # Route); NodePort is the HyperShift default and is passed explicitly so the
    # chosen exposure is visible in the command.
    if _tenant_metallb_enabled; then
        publishing_strategy="LoadBalancer"
    fi

    log [INFO] "Creating tenant HostedCluster ${ZT_TENANT_CLUSTER_NAME} (Agent platform, ${publishing_strategy} exposure, NodePool deferred)..."
    ensure_tenant_namespace "${agent_ns}" || return 1
    ensure_tenant_capi_provider_role "${agent_ns}" || return 1
    hypershift create cluster agent \
        --name "${ZT_TENANT_CLUSTER_NAME}" \
        --namespace "${ns}" \
        --base-domain "${ZT_TENANT_BASE_DOMAIN}" \
        --pull-secret "${OPENSHIFT_PULL_SECRET}" \
        --ssh-key "${ssh_key}" \
        --release-image "${ZT_TENANT_OCP_RELEASE_IMAGE}" \
        --etcd-storage-class "${ETCD_STORAGE_CLASS}" \
        --network-type OVNKubernetes \
        --cluster-cidr "${ZT_TENANT_CLUSTER_NETWORK_CIDR}" \
        --service-cidr "${ZT_TENANT_SERVICE_NETWORK_CIDR}" \
        --agent-namespace "${agent_ns}" \
        --node-pool-replicas -1 \
        --arch "${ZT_TENANT_NODEPOOL_ARCH}" \
        --service-publishing-strategy "${publishing_strategy}"

    _restore_mgmt_kubeconfig
    log [INFO] "Waiting for tenant agent namespace ${agent_ns}..."
    retry 60 10 oc get namespace "${agent_ns}" &>/dev/null
}

create_tenant_infraenv() {
    local ns
    ns="$(zt_tenant_agent_namespace)"
    local out="${ZT_TENANT_GENERATED_DIR}/infraenv.yaml"
    local ssh_key merge_patch
    ssh_key="$(_tenant_ssh_key_path)" || return 1

    mkdir -p "${ZT_TENANT_GENERATED_DIR}"
    process_template \
        "${MANIFESTS_DIR}/zt-tenant/infraenv-template.yaml" \
        "${out}" \
        "<INFRAENV_NAME>" "${ZT_TENANT_INFRAENV_NAME}" \
        "<ZT_TENANT_AGENT_NAMESPACE>" "${ns}" \
        "<ZT_TENANT_RHCOS_OSIMAGE_ARCH>" "${ZT_TENANT_RHCOS_OSIMAGE_ARCH}" \
        "<ZT_TENANT_PULL_SECRET_NAME>" "${ZT_TENANT_PULL_SECRET_NAME}"

    apply_manifest "${out}" true

    merge_patch="$(jq -n --rawfile k "${ssh_key}" '{spec: {sshAuthorizedKey: ($k | rtrimstr("\n"))}}')"
    oc patch infraenv -n "${ns}" "${ZT_TENANT_INFRAENV_NAME}" --type=merge -p "${merge_patch}" || {
        log [ERROR] "Failed to set sshAuthorizedKey on InfraEnv ${ns}/${ZT_TENANT_INFRAENV_NAME}"
        return 1
    }
}

apply_tenant_bmhs() {
    local ns host i name name_var out
    ns="$(zt_tenant_agent_namespace)"
    mkdir -p "${ZT_TENANT_GENERATED_DIR}"

    i=0
    while IFS= read -r host; do
        name_var="WORKER_${host}_NAME"
        name="${!name_var}"
        if [ -z "${name}" ]; then
            name="zt-tenant-worker-${host}"
        fi

        if oc get bmh -n "${ns}" "${name}" &>/dev/null; then
            log [INFO] "BareMetalHost ${ns}/${name} already exists; skipping"
            continue
        fi

        local bmc_ip_var="WORKER_${host}_BMC_IP"
        local bmc_user_var="WORKER_${host}_BMC_USER"
        local bmc_pass_var="WORKER_${host}_BMC_PASSWORD"
        local boot_mac_var="WORKER_${host}_BOOT_MAC"
        local root_dev_var="WORKER_${host}_ROOT_DEVICE"
        local bmc_ip="${!bmc_ip_var}"
        local bmc_user="${!bmc_user_var}"
        local bmc_pass="${!bmc_pass_var}"
        local boot_mac="${!boot_mac_var}"
        local root_dev="${!root_dev_var}"

        local bmh_inspection_mode="disabled"
        if [[ "${BMH_ENABLE_INSPECTION}" == "true" ]]; then
            bmh_inspection_mode="agent"
        fi

        process_template \
            "${MANIFESTS_DIR}/zt-tenant/bmc-secret-tenant-template.yaml" \
            "${ZT_TENANT_GENERATED_DIR}/${name}-bmc-secret.yaml" \
            "<WORKER_NAME>" "$name" \
            "<ZT_TENANT_AGENT_NAMESPACE>" "$ns" \
            "<BMC_USER_BASE64>" "$(printf '%s' "$bmc_user" | base64)" \
            "<BMC_PASSWORD_BASE64>" "$(printf '%s' "$bmc_pass" | base64)"

        process_template \
            "${MANIFESTS_DIR}/zt-tenant/bmh-tenant-template.yaml" \
            "${ZT_TENANT_GENERATED_DIR}/${name}-bmh.yaml" \
            "<WORKER_NAME>" "$name" \
            "<ZT_TENANT_AGENT_NAMESPACE>" "$ns" \
            "<INFRAENV_NAME>" "${ZT_TENANT_INFRAENV_NAME}" \
            "<BOOT_MAC>" "$boot_mac" \
            "<BMC_IP>" "$bmc_ip" \
            "<ROOT_DEVICE>" "$root_dev" \
            "<BMH_INSPECTION_MODE>" "$bmh_inspection_mode"

        retry 5 10 apply_manifest "${ZT_TENANT_GENERATED_DIR}/${name}-bmc-secret.yaml" true
        retry 5 10 apply_manifest "${ZT_TENANT_GENERATED_DIR}/${name}-bmh.yaml" true

        i=$((i + 1))
    done < <(list_zero_trust_dpu_hosts)

    log [INFO] "Submitted ${i} BareMetalHost(s) for tenant discovery"
    _tenant_log_discovery_prereqs
}

wait_for_agents_registered() {
    local ns expected
    ns="$(zt_tenant_agent_namespace)"
    expected="$(list_zero_trust_dpu_hosts | wc -l | tr -d ' ')"
    log [INFO] "Waiting for ${expected} Agent(s) in ${ns} (namespace must exist)..."
    if ! retry 5 5 oc get namespace "${ns}" &>/dev/null; then
        log [ERROR] "Tenant hosted control plane namespace ${ns} missing; HostedCluster not created?"
        return 1
    fi
    if ! retry 120 15 bash -c "oc get agents.agent-install.openshift.io -n '${ns}' --no-headers 2>/dev/null | wc -l | tr -d ' ' | grep -qx ${expected}"; then
        log [ERROR] "Expected ${expected} Agent(s); current:"
        oc get agents.agent-install.openshift.io -n "${ns}" || true
        return 1
    fi
}

label_agents_for_nodepool() {
    local ns a
    ns="$(zt_tenant_agent_namespace)"
    log [INFO] "Labeling Agents with ${ZT_TENANT_AGENT_LABEL_KEY}=${ZT_TENANT_CLUSTER_NAME}..."
    for a in $(oc get agents.agent-install.openshift.io -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        oc label agent -n "${ns}" "${a}" "${ZT_TENANT_AGENT_LABEL_KEY}=${ZT_TENANT_CLUSTER_NAME}" --overwrite
    done
}

approve_agents_if_needed() {
    local ns a approved
    ns="$(zt_tenant_agent_namespace)"
    for a in $(oc get agents.agent-install.openshift.io -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        approved=$(oc get agent -n "${ns}" "${a}" -o jsonpath='{.spec.approved}' 2>/dev/null || echo "false")
        if [ "${approved}" != "true" ]; then
            log [INFO] "Approving Agent ${a}"
            oc patch agent -n "${ns}" "${a}" --type=merge -p '{"spec":{"approved":true}}' || true
        fi
    done
}

_tenant_nodepool_agent_spec_ok() {
    local ns="$1" np="$2"
    local got_label
    got_label=$(oc get nodepool -n "${ns}" "${np}" -o json | jq -r \
        --arg k "${ZT_TENANT_AGENT_LABEL_KEY}" \
        '.spec.platform.agent.agentLabelSelector.matchLabels[$k] // empty' 2>/dev/null || true)
    if [ "${got_label}" != "${ZT_TENANT_CLUSTER_NAME}" ]; then
        log [ERROR] "NodePool ${np}: expected agent label ${ZT_TENANT_AGENT_LABEL_KEY}=${ZT_TENANT_CLUSTER_NAME}, got '${got_label}'"
        return 1
    fi
    return 0
}

ensure_tenant_nodepool() {
    local ns="${CLUSTERS_NAMESPACE}"
    local replicas agent_ns merge_patch
    agent_ns="$(zt_tenant_agent_namespace)"
    replicas="$(list_zero_trust_dpu_hosts | wc -l | tr -d ' ')"

    ensure_hypershift_cli || return 1

    merge_patch="$(jq -n \
        --arg lk "${ZT_TENANT_AGENT_LABEL_KEY}" \
        --arg lv "${ZT_TENANT_CLUSTER_NAME}" \
        --argjson replicas "${replicas}" \
        '{spec: {replicas: $replicas, platform: {agent: {agentLabelSelector: {matchLabels: {($lk): $lv}}}}}}')"

    if oc get nodepool -n "${ns}" "${ZT_TENANT_NODEPOOL_NAME}" &>/dev/null; then
        log [INFO] "NodePool ${ZT_TENANT_NODEPOOL_NAME} exists; setting replicas=${replicas} and agentLabelSelector"
        oc patch nodepool -n "${ns}" "${ZT_TENANT_NODEPOOL_NAME}" --type=merge -p "${merge_patch}" || {
            log [ERROR] "Failed to patch NodePool ${ZT_TENANT_NODEPOOL_NAME}"
            return 1
        }
    else
        log [INFO] "Creating NodePool ${ZT_TENANT_NODEPOOL_NAME} (replicas=${replicas}, agent NS ${agent_ns} on HC)"
        hypershift create nodepool agent \
            --name "${ZT_TENANT_NODEPOOL_NAME}" \
            --namespace "${ns}" \
            --cluster-name "${ZT_TENANT_CLUSTER_NAME}" \
            --replicas "${replicas}" \
            --release-image "${ZT_TENANT_OCP_RELEASE_IMAGE}" \
            --arch "${ZT_TENANT_NODEPOOL_ARCH}"
        _restore_mgmt_kubeconfig
        oc patch nodepool -n "${ns}" "${ZT_TENANT_NODEPOOL_NAME}" --type=merge -p "${merge_patch}" || {
            log [ERROR] "Failed to configure NodePool ${ZT_TENANT_NODEPOOL_NAME} (agent label selector / replicas)"
            return 1
        }
    fi

    _tenant_nodepool_agent_spec_ok "${ns}" "${ZT_TENANT_NODEPOOL_NAME}" || return 1
}

write_tenant_kubeconfig() {
    local ns="${CLUSTERS_NAMESPACE}"
    ensure_hypershift_cli || return 1
    log [INFO] "Writing tenant kubeconfig to ${ZT_TENANT_KUBECONFIG}..."
    hypershift create kubeconfig --namespace "${ns}" --name "${ZT_TENANT_CLUSTER_NAME}" > "${ZT_TENANT_KUBECONFIG}"
    chmod 600 "${ZT_TENANT_KUBECONFIG}" || true
    _restore_mgmt_kubeconfig
}

_tenant_api_reachable() {
    oc --kubeconfig="$1" get nodes --no-headers &>/dev/null
}

_tenant_workers_ready() {
    local kube="$1" expected="$2" ready
    ready=$(oc --kubeconfig="${kube}" get nodes -l '!node-role.kubernetes.io/control-plane' -o json 2>/dev/null | \
        jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' || echo 0)
    [ "${ready:-0}" -ge "${expected}" ]
}

wait_tenant_workers_ready() {
    local expected kube
    expected="$(list_zero_trust_dpu_hosts | wc -l | tr -d ' ')"
    kube="${ZT_TENANT_KUBECONFIG}"
    log [INFO] "Waiting for ${expected} Ready worker node(s) on tenant cluster..."
    retry 120 15 --no-dump-on-failure _tenant_api_reachable "${kube}" || true
    if ! retry 90 20 --no-dump-on-failure _tenant_workers_ready "${kube}" "${expected}"; then
        log [ERROR] "Tenant workers not Ready (want ${expected})"
        oc --kubeconfig="${kube}" get nodes -o wide 2>/dev/null || true
        return 1
    fi
    log [INFO] "Tenant worker nodes Ready: ${expected}/${expected}"
}

# -----------------------------------------------------------------------------
# Exposure: MetalLB VIPs + DNS records (or HyperShift's NodePort default)
# -----------------------------------------------------------------------------

# Production-style exposure is opt-in and all-or-nothing: ZT_TENANT_API_IP (a
# management-cluster MetalLB VIP for the tenant kube-apiserver) and
# ZT_TENANT_INGRESS_IP (a MetalLB VIP inside the tenant cluster for *.apps).
# Leaving both empty keeps HyperShift's NodePort default, where the API is a
# node IP + NodePort and there is no Ingress VIP.
_tenant_metallb_enabled() {
    [ -n "${ZT_TENANT_API_IP:-}" ] && [ -n "${ZT_TENANT_INGRESS_IP:-}" ]
}

# Point KUBECONFIG at the management cluster and pin it in MGMT_KUBECONFIG, so
# the tenant flows can switch context per manifest and always get back.
_init_tenant_mgmt_context() {
    get_kubeconfig
    MGMT_KUBECONFIG="$(canonical_path "${KUBECONFIG}")"
    export MGMT_KUBECONFIG
    export KUBECONFIG="${MGMT_KUBECONFIG}"
    mkdir -p "${ZT_TENANT_GENERATED_DIR}"
}

# Render manifests/zt-tenant/<template> into ZT_TENANT_GENERATED_DIR/<out> and
# apply it. Retried: a CRD or webhook can lag the CSV that installed it.
_apply_zt_manifest() {
    local template="$1" out="$2"
    shift 2
    process_template "${MANIFESTS_DIR}/zt-tenant/${template}" \
        "${ZT_TENANT_GENERATED_DIR}/${out}" "$@" || return 1
    retry 5 10 --no-dump-on-failure apply_manifest "${ZT_TENANT_GENERATED_DIR}/${out}" true
}

_tenant_hc_apiserver_strategy() {
    oc get hostedcluster -n "${CLUSTERS_NAMESPACE}" "${ZT_TENANT_CLUSTER_NAME}" \
        -o jsonpath='{.spec.services[?(@.service=="APIServer")].servicePublishingStrategy.type}' 2>/dev/null || true
}

_tenant_apiserver_strategy_error() {
    local strategy="$1"
    log [ERROR] "Tenant HostedCluster ${ZT_TENANT_CLUSTER_NAME} publishes APIServer as '${strategy:-NodePort}', not LoadBalancer, but ZT_TENANT_API_IP/ZT_TENANT_INGRESS_IP request MetalLB exposure."
    log [ERROR] "HostedCluster spec.services is immutable on the Agent platform, so exposure cannot be changed in place. Recreate the tenant cluster:"
    log [ERROR] "  oc delete hostedcluster -n ${CLUSTERS_NAMESPACE} ${ZT_TENANT_CLUSTER_NAME}"
    log [ERROR] "  make deploy-zt-tenant-cluster"
    log [ERROR] "The tenant workers are reinstalled by the new Assisted run."
}

# Management side: MetalLB operator plus the pool that owns the tenant API VIP.
# HyperShift creates the kube-apiserver Service as type LoadBalancer; with no
# matching auto-assign pool it stays <pending> until ensure_tenant_api_lb points
# it at this pool.
prepare_tenant_metallb_mgmt() {
    _tenant_metallb_enabled || return 0

    log [INFO] "Preparing management-cluster MetalLB pool for tenant API VIP ${ZT_TENANT_API_IP}..."
    ensure_metallb_operator || return 1
    # The DPU pool belongs to dpf-hcp-provisioner-operator; this one is only for
    # the tenant API VIP. The MetalLB CR lives in openshift-operators.
    _apply_zt_manifest metallb-pool-template.yaml metallb-pool-mgmt.yaml \
        "<METALLB_NAMESPACE>" "openshift-operators" \
        "<METALLB_POOL_NAME>" "zt-tenant-api" \
        "<METALLB_IP>" "${ZT_TENANT_API_IP}"
}

# The pool has autoAssign=false, so the HyperShift-created Service needs the pool
# annotation before MetalLB hands out the VIP.
ensure_tenant_api_lb() {
    _tenant_metallb_enabled || return 0

    local ns="${CLUSTERS_NAMESPACE}-${ZT_TENANT_CLUSTER_NAME}"

    wait_for_resource "${ns}" service kube-apiserver 60 10 || {
        log [ERROR] "Tenant kube-apiserver Service ${ns}/kube-apiserver not found; is the HostedCluster reconciling?"
        return 1
    }

    oc annotate service -n "${ns}" kube-apiserver \
        "metallb.universe.tf/address-pool=zt-tenant-api" --overwrite >/dev/null || {
        log [ERROR] "Failed to annotate ${ns}/kube-apiserver with MetalLB pool zt-tenant-api"
        return 1
    }

    wait_for_lb_ip "${ns}" kube-apiserver "${ZT_TENANT_API_IP}" || return 1
    log [INFO] "Tenant API is published at https://${ZT_TENANT_API_IP}:6443"
}

# The metallb-ingress Service forwards VIP:80/443 to the router pods, which must
# own those ports on the worker: HyperShift publishes the tenant ingress with
# HostNetwork. Patch it only when something else is configured.
ensure_tenant_ingress_hostnetwork() {
    local type
    type=$(oc get ingresscontroller default -n openshift-ingress-operator \
        -o jsonpath='{.spec.endpointPublishingStrategy.type}' 2>/dev/null || true)
    if [ "${type}" = "HostNetwork" ]; then
        log [INFO] "Tenant ingress already publishes with HostNetwork"
        return 0
    fi
    log [INFO] "Setting tenant ingress endpointPublishingStrategy to HostNetwork (was '${type:-unset}')..."
    # Patches spec, so the write is authoritative: no wait needed afterwards.
    oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p \
        '{"spec":{"endpointPublishingStrategy":{"type":"HostNetwork","hostNetwork":{"protocol":"TCP","httpPort":80,"httpsPort":443,"statsPort":1936}}}}'
}

# Guest side: MetalLB inside the tenant cluster (its own OLM), then the
# metallb-ingress LoadBalancer Service in openshift-ingress. Runs against the
# tenant kubeconfig; the caller provides the subshell that exports it.
configure_tenant_ingress_lb() {
    _tenant_metallb_enabled || return 0

    local kube="${ZT_TENANT_KUBECONFIG}"
    if [ ! -f "${kube}" ]; then
        log [ERROR] "Tenant kubeconfig ${kube} not found; cannot configure the tenant ingress VIP"
        return 1
    fi

    log [INFO] "Installing MetalLB in the tenant cluster for ingress VIP ${ZT_TENANT_INGRESS_IP}..."
    (
        export KUBECONFIG="${kube}"

        # Install the operator only when it is not already enabled in the tenant
        # cluster: a re-run (or a tenant prepared by hand) skips the OLM waits.
        if metallb_enabled "metallb-system" metallb; then
            log [INFO] "MetalLB is already enabled in the tenant cluster (metallb-system/metallb). Skipping the operator install."
        else
            _apply_zt_manifest metallb-operator-template.yaml metallb-operator.yaml \
                "<METALLB_NAMESPACE>" "metallb-system" || exit 1
            wait_for_csv_succeeded "metallb-system" "metallb-operator" || exit 1

            # The MetalLB CR needs the CRDs the CSV just registered; applying it
            # in the same file as the Subscription fails ("no matches for kind").
            _apply_zt_manifest metallb-cr-template.yaml metallb-cr.yaml \
                "<METALLB_NAMESPACE>" "metallb-system" || exit 1
            oc wait metallb/metallb -n metallb-system --for=condition=Available --timeout=600s || exit 1
        fi

        ensure_tenant_ingress_hostnetwork || exit 1

        _apply_zt_manifest metallb-pool-template.yaml metallb-pool-tenant.yaml \
            "<METALLB_NAMESPACE>" "metallb-system" \
            "<METALLB_POOL_NAME>" "metallb" \
            "<METALLB_IP>" "${ZT_TENANT_INGRESS_IP}" || exit 1

        _apply_zt_manifest metallb-ingress-service-template.yaml metallb-ingress-service.yaml \
            "<METALLB_POOL_NAME>" "metallb" || exit 1

        wait_for_lb_ip "openshift-ingress" metallb-ingress "${ZT_TENANT_INGRESS_IP}" || exit 1
    ) || {
        log [ERROR] "Failed to publish the tenant ingress at ${ZT_TENANT_INGRESS_IP}"
        return 1
    }

    log [INFO] "Tenant ingress is published at https://*.apps.${ZT_TENANT_CLUSTER_NAME}.${ZT_TENANT_BASE_DOMAIN} (${ZT_TENANT_INGRESS_IP})"
}

# Address that serves the management cluster's ingress routes: INGRESS_VIP on
# multi-node clusters, the single node's internal IP on SNO.
_management_ingress_ip() {
    if [ -n "${INGRESS_VIP:-}" ]; then
        echo "${INGRESS_VIP}"
        return 0
    fi
    oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true
}

_tenant_api_server_url() {
    [ -f "${ZT_TENANT_KUBECONFIG}" ] || return 0
    sed -n 's/^[[:space:]]*server:[[:space:]]*//p' "${ZT_TENANT_KUBECONFIG}" 2>/dev/null | head -n 1
}

# DNS records the tenant needs, written under ZT_TENANT_GENERATED_DIR (this repo
# never publishes DNS; see docs/user-guide/configuration.md for the records and
# how to create them):
#   api.<cluster>.<base-domain>          API server (management MetalLB VIP)
#   *.apps.<cluster>.<base-domain>       tenant ingress (guest MetalLB VIP)
#   Route-published control-plane hosts  management ingress VIP
write_tenant_dns_records() {
    local domain api_host out hosts_out route_host api_url mgmt_ip
    local -a route_hosts=()

    domain="${ZT_TENANT_CLUSTER_NAME}.${ZT_TENANT_BASE_DOMAIN}"
    api_host="api.${domain}"
    out="${ZT_TENANT_GENERATED_DIR}/dns-records.txt"
    hosts_out="${ZT_TENANT_GENERATED_DIR}/etc-hosts.txt"
    mkdir -p "${ZT_TENANT_GENERATED_DIR}"

    if _tenant_metallb_enabled; then
        # Hosted control plane services (OAuth, Konnectivity, Ignition) are
        # published as Routes on the management cluster, and their host names are
        # only known after creation.
        mgmt_ip="$(_management_ingress_ip)"
        while IFS= read -r route_host; do
            [ -n "${route_host}" ] && route_hosts+=("${route_host}")
        done < <(oc get route -n "$(zt_tenant_agent_namespace)" \
            -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null)
    else
        api_url="$(_tenant_api_server_url)"
    fi

    {
        echo "# Tenant HostedCluster ${ZT_TENANT_CLUSTER_NAME} DNS records"
        echo "# Generated by scripts/zt-tenant-cluster.sh; publish them in the zone that serves ${ZT_TENANT_BASE_DOMAIN}."
        echo
        if _tenant_metallb_enabled; then
            echo "# API server - management-cluster MetalLB VIP (HyperShift LoadBalancer publishing)"
            echo "${api_host}. IN A ${ZT_TENANT_API_IP}"
            echo
            echo "# Tenant ingress - MetalLB VIP of the metallb-ingress Service in the tenant cluster"
            echo "*.apps.${domain}. IN A ${ZT_TENANT_INGRESS_IP}"
            if [ ${#route_hosts[@]} -gt 0 ]; then
                echo
                echo "# Hosted control plane Routes, served by the MANAGEMENT cluster ingress"
                for route_host in "${route_hosts[@]}"; do
                    echo "${route_host}. IN A ${mgmt_ip:-<management-ingress-ip>}"
                done
            fi
        else
            echo "# HyperShift NodePort publishing: no API VIP and no *.apps Ingress VIP."
            echo "# API endpoint from the tenant kubeconfig:"
            echo "#   ${ZT_TENANT_KUBECONFIG} -> ${api_url}"
            echo "# For the web console, point each *.apps.${domain} name at a tenant worker:"
            oc --kubeconfig "${ZT_TENANT_KUBECONFIG}" get nodes \
                -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null |
                sed 's/^/#   /' || true
        fi
    } > "${out}"

    # /etc/hosts cannot express a wildcard; list the names behind it so a single
    # host can reach the console, OAuth and downloads without publishing DNS.
    {
        echo "# Test-only /etc/hosts entries for tenant ${ZT_TENANT_CLUSTER_NAME};"
        echo "# publish the wildcard record in DNS for every other client."
        if _tenant_metallb_enabled; then
            echo "${ZT_TENANT_API_IP} ${api_host}"
            for route_host in console-openshift-console oauth-openshift downloads-openshift-console canary-openshift-ingress-canary; do
                echo "${ZT_TENANT_INGRESS_IP} ${route_host}.apps.${domain}"
            done
            for route_host in "${route_hosts[@]}"; do
                echo "${mgmt_ip} ${route_host}"
            done
        fi
    } > "${hosts_out}"

    log [INFO] "Tenant DNS records written to ${out} (test /etc/hosts entries: ${hosts_out})"
    if _tenant_metallb_enabled; then
        log [INFO] "  ${api_host} -> ${ZT_TENANT_API_IP} (API, management MetalLB)"
        log [INFO] "  *.apps.${domain} -> ${ZT_TENANT_INGRESS_IP} (tenant MetalLB)"
    else
        log [INFO] "  ${api_host} is not published: the tenant uses HyperShift's NodePort default (endpoint ${api_url})"
    fi
}

# Day-2 entry point: apply the exposure to an existing tenant HostedCluster and
# write its DNS records. No-op (with a hint) when the VIPs are not configured.
configure_zt_tenant_loadbalancer() {
    _init_tenant_mgmt_context

    validate_zt_tenant_configuration || return 1

    if ! _tenant_metallb_enabled; then
        log [INFO] "ZT_TENANT_API_IP/ZT_TENANT_INGRESS_IP are empty; the tenant keeps HyperShift's NodePort exposure. Nothing to configure."
        return 0
    fi

    if ! oc get hostedcluster -n "${CLUSTERS_NAMESPACE}" "${ZT_TENANT_CLUSTER_NAME}" &>/dev/null; then
        log [ERROR] "HostedCluster ${ZT_TENANT_CLUSTER_NAME} not found in ${CLUSTERS_NAMESPACE}; run make deploy-zt-tenant-cluster first"
        return 1
    fi

    prepare_tenant_metallb_mgmt || return 1

    local strategy
    strategy="$(_tenant_hc_apiserver_strategy)"
    if [ "${strategy}" = "LoadBalancer" ]; then
        ensure_tenant_api_lb || return 1
    else
        _tenant_apiserver_strategy_error "${strategy}"
        log [WARN] "Continuing with the tenant ingress VIP and DNS records; the API stays at its NodePort endpoint."
    fi

    configure_tenant_ingress_lb || return 1
    write_tenant_dns_records
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

deploy_zt_tenant_cluster() {
    _init_tenant_mgmt_context

    validate_zt_tenant_configuration || return 1
    wait_for_dpfhcp_provisioner_ready || return 1

    # MetalLB first: the tenant kube-apiserver Service stays <pending> until the
    # operator and the tenant API pool exist.
    prepare_tenant_metallb_mgmt || return 1

    ensure_mce_assisted || return 1
    ensure_agent_service_config || return 1
    ensure_metal3_watch_all_namespaces || return 1

    create_tenant_hostedcluster_skip_nodepool || return 1
    wait_tenant_hosted_cluster_platform_ready || return 1
    ensure_tenant_api_lb || return 1

    local agent_ns
    agent_ns="$(zt_tenant_agent_namespace)"
    create_tenant_pull_secret "${agent_ns}" || return 1
    create_tenant_infraenv || return 1
    apply_tenant_bmhs || return 1

    wait_for_agents_registered || return 1
    label_agents_for_nodepool || return 1
    approve_agents_if_needed || return 1

    wait_tenant_hosted_cluster_for_nodepool || return 1
    ensure_tenant_nodepool || return 1

    write_tenant_kubeconfig || return 1
    wait_tenant_workers_ready || return 1

    configure_tenant_ingress_lb || return 1
    write_tenant_dns_records

    log [INFO] "Tenant HostedCluster ${ZT_TENANT_CLUSTER_NAME} is ready; kubeconfig: ${ZT_TENANT_KUBECONFIG}"
}

main() {
    case "${1:-deploy}" in
        deploy)
            deploy_zt_tenant_cluster
            ;;
        validate)
            # Offline env check only; no cluster calls.
            validate_zt_tenant_configuration
            ;;
        preflight)
            # First step of `make all-zt`: validate the tenant env before the
            # cluster work so a bad ZT_TENANT_* value fails in seconds.
            if [ "${ZT_DEPLOY_TENANT_CLUSTER}" = "true" ]; then
                validate_zt_tenant_configuration
            else
                log [INFO] "ZT_DEPLOY_TENANT_CLUSTER is not true; skipping tenant configuration validation"
            fi
            ;;
        deploy-if-enabled)
            # Last step of `make all-zt`: finish the three-cluster flow only
            # when requested.
            if [ "${ZT_DEPLOY_TENANT_CLUSTER}" = "true" ]; then
                log [INFO] "ZT_DEPLOY_TENANT_CLUSTER=true; deploying tenant HostedCluster"
                deploy_zt_tenant_cluster
            else
                log [INFO] "ZT_DEPLOY_TENANT_CLUSTER is not true; skipping tenant HostedCluster deployment"
            fi
            ;;
        configure-loadbalancer)
            # Day-2: apply the MetalLB exposure (guest ingress + API when the
            # HostedCluster was created with LoadBalancer publishing) and write
            # the DNS records for an existing tenant cluster.
            configure_zt_tenant_loadbalancer
            ;;
        *)
            log [INFO] "Usage: $0 [deploy|validate|preflight|deploy-if-enabled|configure-loadbalancer]"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
