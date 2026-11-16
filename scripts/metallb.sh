#!/usr/bin/env bash
# metallb.sh — MetalLB helpers shared by the DPF flow (scripts/dpf.sh) and the
# Zero Trust tenant flow (scripts/zt-tenant-cluster.sh).
#
# Sourced, never executed: callers have already loaded utils.sh/env.sh, so
# MANIFESTS_DIR, GENERATED_DIR, CATALOG_SOURCE_NAME and the log/retry/template
# helpers are available.

# True when a MetalLB instance exists and its operator reports Available=True —
# the operator and its operand are deployed, so there is nothing to install.
# Evaluated against whatever KUBECONFIG is set: openshift-operators on the
# management cluster, metallb-system inside the tenant cluster.
metallb_enabled() {
    local namespace="${1:-openshift-operators}"
    local name="${2:-metallb}"

    oc get metallb "${name}" -n "${namespace}" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null |
        grep -qx True
}

# Install the management-cluster MetalLB operator (Subscription in
# openshift-operators) and the MetalLB CR. Pools are deliberately not created
# here: on the management cluster the dpf-hcp-provisioner-operator owns the DPU
# pool, and the tenant flow owns the tenant API pool.
ensure_metallb_operator() {
    get_kubeconfig

    # Already enabled (installed by make deploy-dpf or an earlier run): do not
    # wait on pods or re-apply anything.
    if metallb_enabled openshift-operators metallb; then
        log [INFO] "MetalLB is already enabled in openshift-operators/metallb. Nothing to install."
        return 0
    fi

    if oc get subscription -n openshift-operators metallb-operator &>/dev/null; then
        log [INFO] "MetalLB subscription already exists. Skipping subscription deployment."
    else
        log [INFO] "Deploying MetalLB subscription..."
        process_template \
            "${MANIFESTS_DIR}/metallb/metallb-subscription.yaml" \
            "${GENERATED_DIR}/metallb-subscription.yaml" \
            "<CATALOG_SOURCE_NAME>" "${CATALOG_SOURCE_NAME}"
        apply_manifest "${GENERATED_DIR}/metallb-subscription.yaml" true || return 1
    fi

    log [INFO] "Waiting for MetalLB operator to be ready..."
    wait_for_pods "openshift-operators" "control-plane=controller-manager" 60 5

    log [INFO] "Creating MetalLB instance..."
    process_template \
        "${MANIFESTS_DIR}/metallb/metallb-objects.yaml" \
        "${GENERATED_DIR}/metallb-objects.yaml"
    retry 5 10 --no-dump-on-failure apply_manifest "${GENERATED_DIR}/metallb-objects.yaml" true
}

# Wait until the CSV whose name starts with <prefix> in a namespace reports phase
# Succeeded (OLM install finished, CRDs registered). The tenant cluster installs
# MetalLB through its own OLM.
wait_for_csv_succeeded() {
    local namespace="$1"
    local name_prefix="$2"

    log "INFO" "Waiting for CSV '${name_prefix}' in ${namespace} to succeed..."
    if ! retry 60 10 --no-dump-on-failure bash -c \
        "oc get csv -n '${namespace}' --no-headers 2>/dev/null | awk -v p='${name_prefix}' '\$NF==\"Succeeded\" && index(\$1, p)==1 {f=1} END {exit !f}'"; then
        log "ERROR" "No Succeeded CSV matching '${name_prefix}' in ${namespace}"
        oc get csv -n "${namespace}" || true
        return 1
    fi
}
