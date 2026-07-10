#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Default to z+1 of the currently running version (e.g. 4.22.2 -> 4.22.3).
# This will fail if z+1 doesn't exist yet. Set MANAGEMENT_UPGRADE_TARGET_VERSION
# explicitly to upgrade to a specific version (including cross-minor).
# Use the last Completed version — during an upgrade, history[0] is the
# in-progress target (state=Partial), not the version we're upgrading from.
CURRENT_VERSION=$(oc get clusterversion version -o jsonpath='{.status.history[?(@.state=="Completed")].version}' | awk '{print $1}')
echo "Current cluster version: ${CURRENT_VERSION}"

if [[ -z "${MANAGEMENT_UPGRADE_TARGET_VERSION:-}" ]]; then
    current_z="${CURRENT_VERSION##*.}"
    MANAGEMENT_UPGRADE_TARGET_VERSION="${CURRENT_VERSION%.*}.$((current_z + 1))"
    unset current_z
    echo "MANAGEMENT_UPGRADE_TARGET_VERSION not set, defaulting to z+1: ${MANAGEMENT_UPGRADE_TARGET_VERSION}"
    echo "Ensure ${CURRENT_VERSION} is not the latest z-stream, or this will fail."
else
    echo "MANAGEMENT_UPGRADE_TARGET_VERSION explicitly set to ${MANAGEMENT_UPGRADE_TARGET_VERSION}"
fi

# Check if upgrade complete every minute
UPGRADE_POLL_INTERVAL=60

# ... but give up after 1.5 hours (90 minutes). Upgrades will
# probably be shorter than this.
#
# TODO: In the future, with large clusters, we may want to make this
# dynamic as a function of cluster size and how many maxUnavailable workers.
UPGRADE_POLL_RETRIES=90

# For now management clusters are always assumed to be x86_64
MANAGEMENT_ARCH="x86_64"

# Resolve a version (e.g. 4.23.0) to a pinned-by-digest image reference.
# Outputs: quay.io/openshift-release-dev/ocp-release@sha256:...
resolve_release_digest() {
    local release_version="$1"

    local release_image_digest
    release_image_digest=$(oc adm release info \
        "quay.io/openshift-release-dev/ocp-release:${release_version}-${MANAGEMENT_ARCH}" \
        -o jsonpath='{.digest}')

    if [[ -z "$release_image_digest" ]]; then
        echo "ERROR: Failed to resolve digest for ${release_version}" >&2
        return 1
    fi

    echo "quay.io/openshift-release-dev/ocp-release@${release_image_digest}"
}

start_upgrade() {
    local target_image="$1"
    oc adm upgrade --allow-explicit-upgrade --to-image="${target_image}"
}

# Poll clusterversion until the version changes from pre_upgrade_version
# and the upgrade finishes (Progressing=False, Available=True).
wait_for_upgrade() {
    local pre_upgrade_version="$1"
    local timeout_minutes=$((UPGRADE_POLL_RETRIES * UPGRADE_POLL_INTERVAL / 60))
    echo "Waiting for upgrade from ${pre_upgrade_version} (timeout: ${timeout_minutes}m)..."

    for ((attempt = 1; attempt <= UPGRADE_POLL_RETRIES; attempt++)); do
        local cv_progressing cv_available cv_version cv_state
        cv_progressing=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)
        cv_available=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
        cv_version=$(oc get clusterversion version -o jsonpath='{.status.history[0].version}' 2>/dev/null || true)
        cv_state=$(oc get clusterversion version -o jsonpath='{.status.history[0].state}' 2>/dev/null || true)

        echo "[${attempt}/${UPGRADE_POLL_RETRIES}] version=${cv_version} state=${cv_state} progressing=${cv_progressing} available=${cv_available}"

        if [[ "$cv_version" != "$pre_upgrade_version" && "$cv_state" == "Completed" && "$cv_progressing" == "False" && "$cv_available" == "True" ]]; then
            echo "Upgrade complete (version: ${cv_version})."
            oc get clusterversion
            return 0
        fi
        sleep "${UPGRADE_POLL_INTERVAL}"
    done

    echo "ERROR: Upgrade timed out."
    oc get clusterversion
    return 1
}

cv_progressing=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')

if [[ "$cv_progressing" == "True" ]]; then
    # Verify the in-flight upgrade is actually targeting our desired version
    in_flight_version=$(oc get clusterversion version -o jsonpath='{.status.history[0].version}')
    if [[ "$in_flight_version" != "$MANAGEMENT_UPGRADE_TARGET_VERSION" ]]; then
        echo "ERROR: Cluster is upgrading to ${in_flight_version}, not ${MANAGEMENT_UPGRADE_TARGET_VERSION}. Aborting."
        exit 1
    fi
    echo "Cluster is already upgrading to ${MANAGEMENT_UPGRADE_TARGET_VERSION}, waiting for it to finish..."
else
    # Resolve to a digest so we can use --allow-explicit-upgrade for versions
    # not in the Cincinnati upgrade graph (cross-minor, EC/RC builds)
    echo "Upgrading management cluster to ${MANAGEMENT_UPGRADE_TARGET_VERSION}"
    target_image=$(resolve_release_digest "${MANAGEMENT_UPGRADE_TARGET_VERSION}") || exit 1
    start_upgrade "${target_image}"
fi

wait_for_upgrade "${CURRENT_VERSION}"

VERIFY_DEPLOYMENT=true "${SCRIPT_DIR}/verify.sh" verify-deployment
