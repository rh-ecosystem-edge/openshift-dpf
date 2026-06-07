#!/bin/bash
# clean.sh - Full teardown of DPF resources in reverse deployment order

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities and configuration
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

CLEANUP_ERRORS=0

run_cleanup_phase() {
    local phase_name="$1"
    shift
    log "INFO" "Phase: ${phase_name}"
    if ! "$@"; then
        log "WARN" "Phase '${phase_name}' completed with errors (continuing)"
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    fi
}

# -----------------------------------------------------------------------------
# DPU Services cleanup
# -----------------------------------------------------------------------------
delete_dpu_services() {
    log "INFO" "Deleting DPU services..."

    # Delete DPUDeployment
    if check_crd_exists "dpudeployments.svc.dpu.nvidia.com"; then
        log "INFO" "Deleting DPUDeployment 'dpudeployment' in ${DPF_OPERATOR_NAMESPACE}..."
        oc delete dpudeployment dpudeployment -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found --timeout=120s || true
    fi

    # Wait for all DPU resources to be gone (up to 15 minutes)
    if check_crd_exists "dpus.provisioning.dpu.nvidia.com"; then
        log "INFO" "Waiting for all DPU resources to be removed (up to 15 minutes)..."
        local attempts=90
        local delay=10
        local count=0
        for i in $(seq 1 "$attempts"); do
            count=$(oc get dpus.provisioning.dpu.nvidia.com -n "${DPF_OPERATOR_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ') || count=0
            if [[ "$count" -eq 0 ]]; then
                log "INFO" "All DPU resources removed"
                break
            fi
            if [[ "$i" -eq "$attempts" ]]; then
                break
            fi
            log "INFO" "Waiting for DPU resources to be removed: $count remaining (attempt $i/$attempts)..."
            sleep "$delay"
        done
        if [[ $count -ne 0 ]]; then
            log "WARN" "Timed out waiting for DPU resources to drain ($count remaining). Continuing cleanup..."
        fi
    fi

    # Delete remaining DPF objects in the namespace
    log "INFO" "Deleting remaining DPF objects in ${DPF_OPERATOR_NAMESPACE}..."

    if check_crd_exists "bfbs.provisioning.dpu.nvidia.com"; then
        oc delete bfbs.provisioning.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi
    if check_crd_exists "dpuflavors.provisioning.dpu.nvidia.com"; then
        oc delete dpuflavors.provisioning.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi
    if check_crd_exists "dpuservicetemplates.svc.dpu.nvidia.com"; then
        oc delete dpuservicetemplates.svc.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi
    if check_crd_exists "dpuserviceconfigurations.svc.dpu.nvidia.com"; then
        oc delete dpuserviceconfigurations.svc.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi
    if check_crd_exists "dpuserviceipams.svc.dpu.nvidia.com"; then
        oc delete dpuserviceipams.svc.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi
    if check_crd_exists "dpuserviceinterfaces.svc.dpu.nvidia.com"; then
        oc delete dpuserviceinterfaces.svc.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi
    if check_crd_exists "dpuservicenads.svc.dpu.nvidia.com"; then
        oc delete dpuservicenads.svc.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi
    if check_crd_exists "dpuservicecredentialrequests.svc.dpu.nvidia.com"; then
        oc delete dpuservicecredentialrequests.svc.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi
    if check_crd_exists "nodesriovdevicepluginconfigs.noderesources.dpu.nvidia.com"; then
        oc delete nodesriovdevicepluginconfigs.noderesources.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    fi

    # Delete all NetworkPolicies in the namespace
    oc delete networkpolicy --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true

    # Delete ClusterRoleBinding on hosted cluster if kubeconfig exists
    if [[ -f "${HOSTED_CLUSTER_NAME}.kubeconfig" ]]; then
        log "INFO" "Deleting ClusterRoleBinding 'dpf-system-scc-privileged' on hosted cluster..."
        KUBECONFIG="${HOSTED_CLUSTER_NAME}.kubeconfig" oc delete clusterrolebinding dpf-system-scc-privileged --ignore-not-found || true
    fi

    log "INFO" "DPU services deleted successfully"
}

# -----------------------------------------------------------------------------
# Hosted Cluster cleanup
# -----------------------------------------------------------------------------
delete_hosted_cluster() {
    log "INFO" "Deleting hosted cluster..."

    # Delete HostedCluster
    log "INFO" "Deleting HostedCluster '${HOSTED_CLUSTER_NAME}' in ${CLUSTERS_NAMESPACE}..."
    oc delete hostedcluster "${HOSTED_CLUSTER_NAME}" -n "${CLUSTERS_NAMESPACE}" --ignore-not-found --timeout=600s || true

    # Wait for hosted control plane namespace to be deleted (up to 10 minutes)
    if check_namespace_exists "${HOSTED_CONTROL_PLANE_NAMESPACE}" 2>/dev/null; then
        log "INFO" "Waiting for namespace ${HOSTED_CONTROL_PLANE_NAMESPACE} to be deleted (up to 10 minutes)..."
        local attempts=60
        local delay=10
        for i in $(seq 1 "$attempts"); do
            if ! oc get namespace "${HOSTED_CONTROL_PLANE_NAMESPACE}" &>/dev/null; then
                log "INFO" "Namespace ${HOSTED_CONTROL_PLANE_NAMESPACE} deleted"
                break
            fi
            if [[ "$i" -eq "$attempts" ]]; then
                log "WARN" "Timed out waiting for namespace ${HOSTED_CONTROL_PLANE_NAMESPACE} to be deleted"
                break
            fi
            log "INFO" "Waiting for namespace deletion (attempt $i/$attempts)..."
            sleep "$delay"
        done
    fi

    # Remove DPF HCP Provisioner Operator (runs dpf.sh as subprocess to avoid shell-option leakage)
    "${SCRIPT_DIR}/dpf.sh" delete-dpf-hcp-provisioner-operator || log "WARN" "HCP provisioner operator cleanup had errors (continuing)"

    log "INFO" "Hosted cluster deleted successfully"
}

# -----------------------------------------------------------------------------
# DPF Operator cleanup
# -----------------------------------------------------------------------------
delete_dpf_operator() {
    log "INFO" "Deleting DPF operator..."

    # Delete DPFOperatorConfig first (has finalizers that need the controller running)
    if check_crd_exists "dpfoperatorconfigs.operator.dpu.nvidia.com"; then
        log "INFO" "Deleting DPFOperatorConfig 'dpfoperatorconfig'..."
        oc delete dpfoperatorconfigs.operator.dpu.nvidia.com dpfoperatorconfig -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found --timeout=120s || true
    fi

    # Delete DPUCluster (all) - also has finalizers requiring the controller
    if check_crd_exists "dpuclusters.provisioning.dpu.nvidia.com"; then
        log "INFO" "Deleting all DPUCluster resources..."
        oc delete dpuclusters.provisioning.dpu.nvidia.com --all -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found --timeout=120s || true
    fi

    # Uninstall helm release after CRs are gone so finalizers can be processed
    if check_helm_release_exists "${DPF_OPERATOR_NAMESPACE}" "dpf-operator"; then
        log "INFO" "Uninstalling dpf-operator helm release..."
        helm uninstall dpf-operator -n "${DPF_OPERATOR_NAMESPACE}" --wait || {
            log "WARN" "Failed to uninstall dpf-operator helm release"
        }
    else
        log "INFO" "Helm release dpf-operator not found, skipping uninstall"
    fi

    # Delete secrets
    log "INFO" "Deleting DPF secrets..."
    oc delete secret dpf-pull-secret -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    oc delete secret ngc-secret -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true
    oc delete secret ngc-registry-secret -n "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found || true

    # Delete ClusterRoleBinding
    log "INFO" "Deleting ClusterRoleBinding 'dpf-system-scc-privileged'..."
    oc delete clusterrolebinding dpf-system-scc-privileged --ignore-not-found || true

    log "INFO" "DPF operator deleted successfully"
}

# -----------------------------------------------------------------------------
# DPU Worker nodes cleanup
# -----------------------------------------------------------------------------
delete_all_dpu_workers() {
    log "INFO" "Deleting all DPU worker nodes..."

    # Get all BMHs with label dpu-capable=true
    local bmh_names
    bmh_names=$(oc get bmh -n openshift-machine-api -l dpu-capable=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

    if [[ -z "$bmh_names" ]]; then
        log "INFO" "No DPU-capable BareMetalHosts found, skipping worker cleanup"
    else
        for bmh_name in $bmh_names; do
            log "INFO" "Processing BMH: $bmh_name"

            # Find associated Machine via annotation (exact match on BMH name)
            local machine_name
            machine_name=$(oc get machines.machine.openshift.io -n openshift-machine-api -o json 2>/dev/null | \
                jq -r --arg bmh "$bmh_name" '.items[] | select(.metadata.annotations["metal3.io/BareMetalHost"] // "" | split("/") | last == $bmh) | .metadata.name' 2>/dev/null || echo "")

            if [[ -n "$machine_name" ]]; then
                # Get the Node name from Machine's status.nodeRef
                local node_name
                node_name=$(oc get machines.machine.openshift.io -n openshift-machine-api "$machine_name" -o jsonpath='{.status.nodeRef.name}' 2>/dev/null || true)

                if [[ -n "$node_name" ]]; then
                    log "INFO" "Deleting Node: $node_name"
                    oc delete node "$node_name" --ignore-not-found || true
                fi

                log "INFO" "Deleting Machine: $machine_name"
                oc delete machines.machine.openshift.io -n openshift-machine-api "$machine_name" --ignore-not-found || true
            fi

            # Patch BMH to disable automated cleaning before deletion
            log "INFO" "Disabling automated cleaning on BMH: $bmh_name"
            oc patch bmh -n openshift-machine-api "$bmh_name" --type=merge \
                -p '{"spec":{"automatedCleaningMode":"disabled"}}' 2>/dev/null || true

            log "INFO" "Deleting BMH: $bmh_name"
            oc delete bmh -n openshift-machine-api "$bmh_name" --ignore-not-found || true
        done
    fi

    # Delete worker-dpu MachineSet
    log "INFO" "Deleting worker-dpu MachineSet..."
    oc delete machineset worker-dpu -n openshift-machine-api --ignore-not-found || true

    # Delete CSR auto-approver resources (reuse worker.sh to avoid duplication)
    log "INFO" "Deleting CSR auto-approver resources..."
    "${SCRIPT_DIR}/worker.sh" delete-csr-auto-approver || log "WARN" "CSR auto-approver cleanup had errors (continuing)"

    log "INFO" "DPU worker nodes deleted successfully"
}

# -----------------------------------------------------------------------------
# Namespace cleanup
# -----------------------------------------------------------------------------
cleanup_namespaces() {
    log "INFO" "Cleaning up namespaces..."

    # Delete DPF operator namespace
    log "INFO" "Deleting namespace ${DPF_OPERATOR_NAMESPACE}..."
    oc delete namespace "${DPF_OPERATOR_NAMESPACE}" --ignore-not-found --timeout=180s || true

    # Remove local kubeconfig file
    if [[ -f "${HOSTED_CLUSTER_NAME}.kubeconfig" ]]; then
        log "INFO" "Removing local kubeconfig file: ${HOSTED_CLUSTER_NAME}.kubeconfig"
        rm -f "${HOSTED_CLUSTER_NAME}.kubeconfig"
    fi

    log "INFO" "Namespace cleanup complete"
}

# -----------------------------------------------------------------------------
# Main orchestrator
# -----------------------------------------------------------------------------
clean_cluster() {
    log "INFO" "Verifying cluster connectivity..."
    if ! oc whoami &>/dev/null; then
        log "ERROR" "Cannot connect to cluster. Ensure KUBECONFIG is set correctly."
        exit 1
    fi
    log "INFO" "Connected to cluster as: $(oc whoami)"

    : "${DPF_OPERATOR_NAMESPACE:?DPF_OPERATOR_NAMESPACE must be set}"
    : "${CLUSTERS_NAMESPACE:?CLUSTERS_NAMESPACE must be set}"
    : "${HOSTED_CLUSTER_NAME:?HOSTED_CLUSTER_NAME must be set and non-empty}"
    : "${HOSTED_CONTROL_PLANE_NAMESPACE:?HOSTED_CONTROL_PLANE_NAMESPACE must be set}"

    log "INFO" "Starting full DPF cluster cleanup..."
    run_cleanup_phase "Delete DPU Services" delete_dpu_services
    run_cleanup_phase "Delete Hosted Cluster" delete_hosted_cluster
    run_cleanup_phase "Delete DPF Operator" delete_dpf_operator
    run_cleanup_phase "Delete DPU Workers" delete_all_dpu_workers
    run_cleanup_phase "Cleanup Namespaces" cleanup_namespaces

    if [[ $CLEANUP_ERRORS -gt 0 ]]; then
        log "WARN" "Cleanup completed with $CLEANUP_ERRORS phase error(s). Review output above."
        exit 1
    fi
    log "INFO" "DPF cluster cleanup complete!"
}

# -----------------------------------------------------------------------------
# Command dispatcher
# -----------------------------------------------------------------------------
case "${1:-}" in
    clean-cluster) clean_cluster ;;
    *)
        echo "Usage: $0 {clean-cluster}"
        exit 1
        ;;
esac
