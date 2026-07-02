#!/bin/bash
# e2e.sh - Run upstream NVIDIA DPF e2e tests against a pre-existing deployment
#
# This script:
# 1. Clones the NVIDIA doca-platform repository at a pinned release tag
# 2. Applies a patch to skip BeforeSuite resource creation (DPF_SKIP_SETUP)
# 3. Runs selected e2e tests via Ginkgo label/focus filtering
#
# Repository: https://github.com/NVIDIA/doca-platform

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -z "${MAKELEVEL:-}" ]; then
    source "${SCRIPT_DIR}/env.sh"
fi
source "${SCRIPT_DIR}/utils.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DPF_UPSTREAM_REPO="${DPF_UPSTREAM_REPO:-https://github.com/NVIDIA/doca-platform.git}"
DPF_UPSTREAM_TAG="${DPF_UPSTREAM_TAG:-public-main}"
DPF_UPSTREAM_DIR="${DPF_UPSTREAM_DIR:-${PROJECT_DIR}/repos/doca-platform}"
DPF_E2E_PATCH="${DPF_E2E_PATCH:-${PROJECT_DIR}/ci/patches/e2e-skip-setup.patch}"

E2E_KUBECONFIG="${E2E_KUBECONFIG:-${KUBECONFIG:-${HOME}/.kube/config}}"
E2E_FOCUS="${E2E_FOCUS:-provisioning-controller leader pod is deleted}"
E2E_LABEL_FILTER="${E2E_LABEL_FILTER:-DPFSystem}"
E2E_TIMEOUT="${E2E_TIMEOUT:-10m}"
E2E_CONFIG="${E2E_CONFIG:-./config-quick.yaml}"

# Go 1.21+ supports automatic toolchain downloading via GOTOOLCHAIN=auto
GO_MIN_VERSION="1.21"

# -----------------------------------------------------------------------------
# Go Version Check
# -----------------------------------------------------------------------------
check_go_version() {
    if ! command -v go &>/dev/null; then
        log "ERROR" "Go is not installed (>= ${GO_MIN_VERSION} required for toolchain auto-download)"
        log "INFO" "Install via: scripts/golang-installation.sh or https://go.dev/dl/"
        return 1
    fi

    local go_version
    go_version=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+')
    if ! printf '%s\n%s\n' "${GO_MIN_VERSION}" "${go_version}" | sort -V -C; then
        log "ERROR" "Go ${go_version} found, but >= ${GO_MIN_VERSION} required for toolchain auto-download"
        log "INFO" "Install via: scripts/golang-installation.sh or https://go.dev/dl/"
        return 1
    fi

    export GOTOOLCHAIN=auto
    log "INFO" "Go version: $(go version) (GOTOOLCHAIN=auto for upstream compatibility)"
}

# -----------------------------------------------------------------------------
# Clone/Update Repository
# -----------------------------------------------------------------------------
setup_repo() {
    log "INFO" "Setting up doca-platform repository (tag: ${DPF_UPSTREAM_TAG})..."

    if [[ -d "${DPF_UPSTREAM_DIR}/.git" ]]; then
        log "INFO" "Repository already cloned at ${DPF_UPSTREAM_DIR}"
    else
        log "INFO" "Shallow-cloning from ${DPF_UPSTREAM_REPO} (ref: ${DPF_UPSTREAM_TAG})..."
        git clone --depth 1 --branch "${DPF_UPSTREAM_TAG}" "${DPF_UPSTREAM_REPO}" "${DPF_UPSTREAM_DIR}"
    fi

    apply_patch
    download_modules
    log "INFO" "Setup complete"
}

# -----------------------------------------------------------------------------
# Apply Patch
# -----------------------------------------------------------------------------
apply_patch() {
    log "INFO" "Applying e2e skip-setup patch..."

    if ! [[ -f "${DPF_E2E_PATCH}" ]]; then
        log "ERROR" "Patch file not found: ${DPF_E2E_PATCH}"
        return 1
    fi

    pushd "${DPF_UPSTREAM_DIR}" > /dev/null
    if git diff --quiet test/e2e/e2e_suite_test.go 2>/dev/null; then
        git apply "${DPF_E2E_PATCH}"
        log "INFO" "Patch applied successfully"
    else
        log "INFO" "Patch already applied (file has local changes)"
    fi
    popd > /dev/null
}

# -----------------------------------------------------------------------------
# Download Go Modules
# -----------------------------------------------------------------------------
download_modules() {
    log "INFO" "Downloading Go modules..."
    pushd "${DPF_UPSTREAM_DIR}" > /dev/null
    go mod download
    popd > /dev/null
    log "INFO" "Go modules ready"
}

# -----------------------------------------------------------------------------
# Run E2E Tests
# -----------------------------------------------------------------------------
run_tests() {
    check_go_version

    if ! [[ -d "${DPF_UPSTREAM_DIR}/.git" ]]; then
        log "ERROR" "Repository not found at ${DPF_UPSTREAM_DIR}. Run 'setup' first."
        return 1
    fi

    # Resolve kubeconfig to absolute path since go test runs from the cloned repo dir
    E2E_KUBECONFIG="$(realpath "${E2E_KUBECONFIG}")"

    log "INFO" "Running e2e tests..."
    log "INFO" "  Kubeconfig:    ${E2E_KUBECONFIG}"
    log "INFO" "  Focus:         ${E2E_FOCUS}"
    log "INFO" "  Label filter:  ${E2E_LABEL_FILTER}"
    log "INFO" "  Config:        ${E2E_CONFIG}"
    log "INFO" "  Timeout:       ${E2E_TIMEOUT}"

    pushd "${DPF_UPSTREAM_DIR}" > /dev/null

    DPF_SKIP_SETUP=true \
    DPF_E2E_COLLECT_RESOURCES=false \
    HELM_REGISTRY=unused \
    DOCKER_IO_REGISTRY=unused \
    TAG=unused \
    NETUTILS_IMAGE=unused \
    go test -v -count=1 -timeout "${E2E_TIMEOUT}" ./test/e2e/ \
        -ginkgo.v \
        -ginkgo.fail-fast \
        -ginkgo.label-filter="${E2E_LABEL_FILTER}" \
        -ginkgo.focus="${E2E_FOCUS}" \
        -e2e.testKubeconfig="${E2E_KUBECONFIG}" \
        -e2e.config="${E2E_CONFIG}" \
        -e2e.skip-cleanup.suite-after=true \
        "$@"

    popd > /dev/null
    log "INFO" "E2E tests complete"
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
clean_repo() {
    if [[ -d "${DPF_UPSTREAM_DIR}" ]]; then
        log "INFO" "Removing ${DPF_UPSTREAM_DIR}..."
        rm -rf "${DPF_UPSTREAM_DIR}"
        log "INFO" "Cleanup complete"
    else
        log "INFO" "Nothing to clean"
    fi
}

# -----------------------------------------------------------------------------
# Command Dispatcher
# -----------------------------------------------------------------------------
case "${1:-}" in
    setup)
        check_go_version
        setup_repo
        ;;
    run)
        shift
        run_tests "$@"
        ;;
    run-full|"")
        check_go_version
        setup_repo
        run_tests
        ;;
    clean)
        clean_repo
        ;;
    *)
        echo "Usage: $0 {setup|run|run-full|clean}"
        echo ""
        echo "Commands:"
        echo "  setup      - Clone upstream repo and apply patch"
        echo "  run        - Run e2e tests (assumes setup is complete)"
        echo "  run-full   - Full workflow: setup + run (default)"
        echo "  clean      - Remove cloned repository"
        echo ""
        echo "Environment Variables:"
        echo "  DPF_UPSTREAM_TAG    - Upstream git ref (default: public-main)"
        echo "  E2E_KUBECONFIG      - Path to kubeconfig (default: KUBECONFIG or ~/.kube/config)"
        echo "  E2E_FOCUS           - Ginkgo focus filter (default: 'provisioning-controller leader pod is deleted')"
        echo "  E2E_LABEL_FILTER    - Ginkgo label filter (default: 'DPFSystem')"
        echo "  E2E_TIMEOUT         - Test timeout (default: 10m)"
        echo "  E2E_CONFIG          - Upstream config file (default: ./config-quick.yaml)"
        echo ""
        exit 1
        ;;
esac
