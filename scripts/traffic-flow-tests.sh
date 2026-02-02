#!/bin/bash
# traffic-flow-tests.sh - Run Kubernetes Traffic Flow Tests for DPF verification
#
# This script:
# 1. Clones the kubernetes-traffic-flow-tests repository
# 2. Sets up the Python virtual environment
# 3. Generates test configuration from template
# 4. Runs traffic flow tests against the deployed DPF cluster
#
# Repository: https://github.com/ovn-kubernetes/kubernetes-traffic-flow-tests

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/utils.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# TFT Repository Configuration
TFT_REPO_URL="${TFT_REPO_URL:-https://github.com/ovn-kubernetes/kubernetes-traffic-flow-tests.git}"
TFT_REPO_REV="${TFT_REPO_REV:-main}"
TFT_WORK_DIR="${TFT_WORK_DIR:-${SCRIPT_DIR}/../repos/kubernetes-traffic-flow-tests}"
TFT_VENV_DIR="${TFT_WORK_DIR}/tft-venv"

# Python Configuration
# TFT requires Python 3.11 due to dataclass kw_only parameter
TFT_PYTHON_VERSION="3.11"
TFT_PYTHON="${TFT_PYTHON:-python${TFT_PYTHON_VERSION}}"

# Test Configuration
TFT_CONFIG_TEMPLATE="${SCRIPT_DIR}/../ci/tft-config.yaml.template"
TFT_CONFIG_OUTPUT="${TFT_WORK_DIR}/tft-config.yaml"

# Test Parameters (can be overridden via environment)
TFT_TEST_CASES="${TFT_TEST_CASES:-1-25}"
TFT_DURATION="${TFT_DURATION:-10}"
TFT_CONNECTION_TYPE="${TFT_CONNECTION_TYPE:-iperf-tcp}"

# Kubeconfig path (relative to working directory by default)
TFT_KUBECONFIG="${TFT_KUBECONFIG:-$(pwd)/kubeconfig.${CLUSTER_NAME}}"

# Node names for TFT (server and client)
# These are the actual Kubernetes node names, NOT BareMetalHost names
# Priority: TFT_*_NODE > HBN_HOSTNAME_NODE* (minus wildcard) > WORKER_*_NAME
_hbn_node1="${HBN_HOSTNAME_NODE1%\*}"
_hbn_node2="${HBN_HOSTNAME_NODE2%\*}"
TFT_SERVER_NODE="${TFT_SERVER_NODE:-${_hbn_node1:-${WORKER_1_NAME}}}"
TFT_CLIENT_NODE="${TFT_CLIENT_NODE:-${_hbn_node2:-${WORKER_2_NAME}}}"

# -----------------------------------------------------------------------------
# Ensure Python 3.11 is available (install if missing)
# -----------------------------------------------------------------------------
ensure_python() {
    log "INFO" "Checking for Python ${TFT_PYTHON_VERSION}..."
    
    # Check if required Python version is available
    if command -v "${TFT_PYTHON}" &>/dev/null; then
        local version
        version=$("${TFT_PYTHON}" --version 2>&1)
        log "INFO" "Found ${version}"
        return 0
    fi
    
    log "WARN" "${TFT_PYTHON} not found, attempting to install..."
    
    # Detect package manager and install Python
    if command -v dnf &>/dev/null; then
        log "INFO" "Installing Python ${TFT_PYTHON_VERSION} via dnf..."
        sudo dnf install -y "python${TFT_PYTHON_VERSION}" "python${TFT_PYTHON_VERSION}-pip" "python${TFT_PYTHON_VERSION}-devel" || {
            log "ERROR" "Failed to install Python ${TFT_PYTHON_VERSION} via dnf"
            return 1
        }
    elif command -v yum &>/dev/null; then
        log "INFO" "Installing Python ${TFT_PYTHON_VERSION} via yum..."
        sudo yum install -y "python${TFT_PYTHON_VERSION}" "python${TFT_PYTHON_VERSION}-pip" "python${TFT_PYTHON_VERSION}-devel" || {
            log "ERROR" "Failed to install Python ${TFT_PYTHON_VERSION} via yum"
            return 1
        }
    elif command -v apt-get &>/dev/null; then
        log "INFO" "Installing Python ${TFT_PYTHON_VERSION} via apt..."
        sudo apt-get update
        sudo apt-get install -y "python${TFT_PYTHON_VERSION}" "python${TFT_PYTHON_VERSION}-venv" "python${TFT_PYTHON_VERSION}-dev" || {
            log "ERROR" "Failed to install Python ${TFT_PYTHON_VERSION} via apt"
            return 1
        }
    else
        log "ERROR" "No supported package manager found (dnf/yum/apt)"
        log "ERROR" "Please install Python ${TFT_PYTHON_VERSION} manually"
        return 1
    fi
    
    # Verify installation
    if command -v "${TFT_PYTHON}" &>/dev/null; then
        local version
        version=$("${TFT_PYTHON}" --version 2>&1)
        log "INFO" "Successfully installed ${version}"
        return 0
    else
        log "ERROR" "Python ${TFT_PYTHON_VERSION} installation failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Clone/Update Repository
# -----------------------------------------------------------------------------
setup_tft_repo() {
    log "INFO" "Setting up traffic-flow-tests repository..."
    
    if [[ -d "${TFT_WORK_DIR}/.git" ]]; then
        log "INFO" "Repository exists, fetching updates..."
        pushd "${TFT_WORK_DIR}" > /dev/null
        git fetch origin
        git checkout "${TFT_REPO_REV}"
        if git rev-parse --verify "origin/${TFT_REPO_REV}" &>/dev/null; then
            # It's a branch, pull latest
            git pull origin "${TFT_REPO_REV}" || true
        fi
        popd > /dev/null
    else
        log "INFO" "Cloning repository from ${TFT_REPO_URL}..."
        git clone "${TFT_REPO_URL}" "${TFT_WORK_DIR}"
        pushd "${TFT_WORK_DIR}" > /dev/null
        git checkout "${TFT_REPO_REV}"
        popd > /dev/null
    fi
    
    log "INFO" "Repository setup complete at ${TFT_WORK_DIR}"
    log "INFO" "Using revision: ${TFT_REPO_REV}"
}

# -----------------------------------------------------------------------------
# Setup Python Virtual Environment
# -----------------------------------------------------------------------------
setup_venv() {
    log "INFO" "Setting up Python virtual environment..."
    
    # Ensure Python 3.11 is available
    ensure_python || return 1
    
    if [[ ! -d "${TFT_VENV_DIR}" ]]; then
        log "INFO" "Creating virtual environment at ${TFT_VENV_DIR} using ${TFT_PYTHON}..."
        "${TFT_PYTHON}" -m venv "${TFT_VENV_DIR}"
    else
        # Verify existing venv has correct Python version
        local venv_version
        venv_version=$("${TFT_VENV_DIR}/bin/python" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
        
        if [[ "$venv_version" != "${TFT_PYTHON_VERSION}" ]]; then
            log "WARN" "Existing venv has Python $venv_version, recreating with ${TFT_PYTHON}..."
            rm -rf "${TFT_VENV_DIR}"
            "${TFT_PYTHON}" -m venv "${TFT_VENV_DIR}"
        fi
    fi
    
    log "INFO" "Activating virtual environment..."
    # shellcheck disable=SC1091
    source "${TFT_VENV_DIR}/bin/activate"
    
    log "INFO" "Upgrading pip and installing dependencies..."
    pip install --upgrade pip
    pip install -r "${TFT_WORK_DIR}/requirements.txt"
    
    log "INFO" "Python environment ready"
}

# -----------------------------------------------------------------------------
# Generate Test Configuration
# -----------------------------------------------------------------------------
generate_config() {
    log "INFO" "Generating traffic flow test configuration..."
    
    if [[ ! -f "${TFT_CONFIG_TEMPLATE}" ]]; then
        log "ERROR" "Configuration template not found: ${TFT_CONFIG_TEMPLATE}"
        return 1
    fi
    
    # Validate required node names
    if [[ -z "${TFT_SERVER_NODE}" ]] || [[ -z "${TFT_CLIENT_NODE}" ]]; then
        log "ERROR" "TFT_SERVER_NODE and TFT_CLIENT_NODE must be set"
        log "ERROR" "These are derived from HBN_HOSTNAME_NODE1/NODE2 or can be set directly"
        log "ERROR" "They should match actual Kubernetes node names (not BareMetalHost names)"
        return 1
    fi
    
    # Resolve kubeconfig path to absolute path
    local kubeconfig_path
    if [[ -f "${TFT_KUBECONFIG}" ]]; then
        kubeconfig_path="$(cd "$(dirname "${TFT_KUBECONFIG}")" && pwd)/$(basename "${TFT_KUBECONFIG}")"
    else
        log "WARN" "Kubeconfig not found at ${TFT_KUBECONFIG}"
        kubeconfig_path="${TFT_KUBECONFIG}"
    fi
    
    log "INFO" "Test configuration:"
    log "INFO" "  Test cases: ${TFT_TEST_CASES}"
    log "INFO" "  Duration: ${TFT_DURATION}s"
    log "INFO" "  Connection type: ${TFT_CONNECTION_TYPE}"
    log "INFO" "  Server node: ${TFT_SERVER_NODE}"
    log "INFO" "  Client node: ${TFT_CLIENT_NODE}"
    log "INFO" "  Kubeconfig: ${kubeconfig_path}"
    
    # Process template
    cp "${TFT_CONFIG_TEMPLATE}" "${TFT_CONFIG_OUTPUT}"
    
    # Replace placeholders
    sed -i "s|__TFT_TEST_CASES__|${TFT_TEST_CASES}|g" "${TFT_CONFIG_OUTPUT}"
    sed -i "s|__TFT_DURATION__|${TFT_DURATION}|g" "${TFT_CONFIG_OUTPUT}"
    sed -i "s|__TFT_CONNECTION_TYPE__|${TFT_CONNECTION_TYPE}|g" "${TFT_CONFIG_OUTPUT}"
    sed -i "s|__TFT_SERVER_NODE__|${TFT_SERVER_NODE}|g" "${TFT_CONFIG_OUTPUT}"
    sed -i "s|__TFT_CLIENT_NODE__|${TFT_CLIENT_NODE}|g" "${TFT_CONFIG_OUTPUT}"
    sed -i "s|__TFT_KUBECONFIG__|${kubeconfig_path}|g" "${TFT_CONFIG_OUTPUT}"
    
    log "INFO" "Configuration generated: ${TFT_CONFIG_OUTPUT}"
}

# -----------------------------------------------------------------------------
# Run Traffic Flow Tests
# -----------------------------------------------------------------------------
run_tests() {
    log "INFO" "Running traffic flow tests..."
    
    # Create results directory - tft.py will write files with pattern: <output_base><timestamp>.json
    local results_base_dir="${TFT_WORK_DIR}/results"
    mkdir -p "${results_base_dir}"
    
    # Generate output base path (tft.py appends millisecond timestamp and .json)
    local output_base="${results_base_dir}/$(date +%Y%m%d_%H%M%S)"

    log "INFO" "Test results will be saved with base: ${output_base}"
    
    pushd "${TFT_WORK_DIR}" > /dev/null
    
    # Ensure venv is activated
    # shellcheck disable=SC1091
    source "${TFT_VENV_DIR}/bin/activate"
    
    # Run the tests
    log "INFO" "Executing: ./tft.py ${TFT_CONFIG_OUTPUT} --output-base ${output_base}"

    # Run tft.py - ignore exit code as it may return 0 even on test failures
    ./tft.py "${TFT_CONFIG_OUTPUT}" --output-base "${output_base}" || true
    
    # Find the results JSON file - tft.py writes to <output_base><milliseconds>.json
    local results_file
    results_file=$(find "${results_base_dir}" -maxdepth 1 -name "$(basename "${output_base}")*.json" -type f 2>/dev/null | sort | tail -1)

    # Check test results from JSON file
    local test_result=0
    if [[ -n "${results_file}" ]] && [[ -f "${results_file}" ]]; then
        log "INFO" "Results saved to: ${results_file}"

        # Check for success in JSON - look for "success": false or "Success": false
        if grep -qE '"[Ss]uccess"\s*:\s*false' "${results_file}"; then
            test_result=1
        fi
    else
        log "WARN" "No JSON results file found matching ${output_base}*.json"
        log "INFO" "Available result files in ${results_base_dir}:"
        ls -la "${results_base_dir}" 2>/dev/null || true
        test_result=1
    fi

    # Report pass/fail
    if [[ ${test_result} -eq 0 ]]; then
        log "INFO" "================================================================================"
        log "INFO" "Traffic flow tests PASSED"
        log "INFO" "================================================================================"
    else
        log "ERROR" "================================================================================"
        log "ERROR" "Traffic flow tests FAILED"
        log "ERROR" "================================================================================"
    fi
    
    # Display results summary
    if [[ -f "./print_results.py" ]] && [[ -n "${results_file}" ]] && [[ -f "${results_file}" ]]; then
        log "INFO" ""
        log "INFO" "================================================================================"
        log "INFO" "TEST RESULTS SUMMARY"
        log "INFO" "================================================================================"
        ./print_results.py "${results_file}" 2>/dev/null || true
    fi
    
    popd > /dev/null
    return ${test_result}
}

# -----------------------------------------------------------------------------
# Full Test Workflow
# -----------------------------------------------------------------------------
run_full_test() {
    log "INFO" "================================================================================"
    log "INFO" "Starting Traffic Flow Tests"
    log "INFO" "================================================================================"
    
    setup_tft_repo
    setup_venv
    generate_config
    run_tests
}

# -----------------------------------------------------------------------------
# Show Results from Previous Run
# -----------------------------------------------------------------------------
show_results() {
    local results_dir="${TFT_WORK_DIR}/results"
    
    if [[ ! -d "${results_dir}" ]]; then
        log "ERROR" "No results directory found at ${results_dir}"
        return 1
    fi
    
    # Find the most recent results JSON file (tft.py writes files directly to results dir)
    local results_file
    results_file=$(find "${results_dir}" -maxdepth 1 -name "*.json" -type f 2>/dev/null | sort | tail -1)
    
    if [[ -z "${results_file}" ]]; then
        log "ERROR" "No test results found in ${results_dir}"
        log "INFO" "Available files:"
        ls -la "${results_dir}" 2>/dev/null || true
        return 1
    fi
    
    log "INFO" "Latest results file: ${results_file}"
    
    pushd "${TFT_WORK_DIR}" > /dev/null
    
    # Activate venv if it exists
    if [[ -f "${TFT_VENV_DIR}/bin/activate" ]]; then
        # shellcheck disable=SC1091
        source "${TFT_VENV_DIR}/bin/activate"
    fi
    
    if [[ -f "./print_results.py" ]]; then
        log "INFO" "================================================================================"
        log "INFO" "TEST RESULTS SUMMARY"
        log "INFO" "================================================================================"
        ./print_results.py "${results_file}"
    else
        log "ERROR" "print_results.py not found - run 'setup' first"
    fi
    
    popd > /dev/null
    
    # List all available results
    echo ""
    echo "All available test results:"
    ls -lt "${results_dir}"/*.json 2>/dev/null | head -10 || echo "No JSON files found"
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
cleanup() {
    log "INFO" "Cleaning up traffic flow tests..."
    
    if [[ -d "${TFT_WORK_DIR}" ]]; then
        log "INFO" "Removing ${TFT_WORK_DIR}..."
        rm -rf "${TFT_WORK_DIR}"
    fi
    
    log "INFO" "Cleanup complete"
}

# -----------------------------------------------------------------------------
# Show Configuration
# -----------------------------------------------------------------------------
show_config() {
    echo "Traffic Flow Tests Configuration"
    echo "================================="
    echo ""
    echo "Repository:"
    echo "  TFT_REPO_URL:       ${TFT_REPO_URL}"
    echo "  TFT_REPO_REV:       ${TFT_REPO_REV}"
    echo "  TFT_WORK_DIR:       ${TFT_WORK_DIR}"
    echo ""
    echo "Python:"
    echo "  Required version:   ${TFT_PYTHON_VERSION}"
    echo "  TFT_PYTHON:         ${TFT_PYTHON}"
    if command -v "${TFT_PYTHON}" &>/dev/null; then
        echo "  Status:             $(${TFT_PYTHON} --version 2>&1)"
    else
        echo "  Status:             NOT INSTALLED (will be installed automatically)"
    fi
    echo ""
    echo "Test Parameters:"
    echo "  TFT_TEST_CASES:     ${TFT_TEST_CASES}"
    echo "  TFT_DURATION:       ${TFT_DURATION}s"
    echo "  TFT_CONNECTION_TYPE: ${TFT_CONNECTION_TYPE}"
    echo ""
    echo "Cluster:"
    echo "  TFT_SERVER_NODE:    ${TFT_SERVER_NODE:-<not set>}"
    echo "  TFT_CLIENT_NODE:    ${TFT_CLIENT_NODE:-<not set>}"
    echo "  TFT_KUBECONFIG:     ${TFT_KUBECONFIG}"
    echo ""
    echo "Node name sources (priority order):"
    echo "  1. TFT_SERVER_NODE / TFT_CLIENT_NODE (if set)"
    echo "  2. HBN_HOSTNAME_NODE1/2 (minus wildcard): ${HBN_HOSTNAME_NODE1:-<not set>} / ${HBN_HOSTNAME_NODE2:-<not set>}"
    echo "  3. WORKER_1_NAME / WORKER_2_NAME: ${WORKER_1_NAME:-<not set>} / ${WORKER_2_NAME:-<not set>}"
    echo ""
    echo "Excluded Test Cases (known failures):"
    echo "  4  - POD_TO_HOST_DIFF_NODE"
    echo "  8  - POD_TO_CLUSTER_IP_TO_HOST_DIFF_NODE"
    echo "  20 - HOST_TO_CLUSTER_IP_TO_HOST_DIFF_NODE"
}

# -----------------------------------------------------------------------------
# Command Dispatcher
# -----------------------------------------------------------------------------
case "${1:-}" in
    setup)
        setup_tft_repo
        setup_venv
        ;;
    generate-config)
        generate_config
        ;;
    run)
        run_tests
        ;;
    run-full|"")
        run_full_test
        ;;
    cleanup)
        cleanup
        ;;
    show-config)
        show_config
        ;;
    show-results|results)
        show_results
        ;;
    *)
        echo "Usage: $0 {setup|generate-config|run|run-full|cleanup|show-config|show-results}"
        echo ""
        echo "Commands:"
        echo "  setup          - Clone repository and setup Python environment"
        echo "  generate-config - Generate test configuration from template"
        echo "  run            - Run tests (assumes setup is complete)"
        echo "  run-full       - Full workflow: setup + generate-config + run (default)"
        echo "  cleanup        - Remove cloned repository and virtual environment"
        echo "  show-config    - Display current configuration"
        echo "  show-results   - Display results from the most recent test run"
        echo ""
        echo "Environment Variables:"
        echo "  TFT_REPO_URL        - Repository URL (default: https://github.com/ovn-kubernetes/kubernetes-traffic-flow-tests.git)"
        echo "  TFT_REPO_REV        - Git revision to checkout (default: main)"
        echo "  TFT_TEST_CASES      - Test cases to run (default: 1-25)"
        echo "  TFT_DURATION        - Duration per test in seconds (default: 10)"
        echo "  TFT_CONNECTION_TYPE - Connection type: iperf-tcp, iperf-udp, etc. (default: iperf-tcp)"
        echo "  TFT_KUBECONFIG      - Path to cluster kubeconfig"
        echo "  TFT_SERVER_NODE     - Kubernetes node name for server (default: from HBN_HOSTNAME_NODE1)"
        echo "  TFT_CLIENT_NODE     - Kubernetes node name for client (default: from HBN_HOSTNAME_NODE2)"
        echo "  TFT_PYTHON          - Python interpreter (default: python3.11)"
        echo ""
        echo "Note: Python 3.11 is required. If not installed, the script will attempt"
        echo "      to install it automatically using dnf/yum/apt."
        echo ""
        echo "Node names fallback: TFT_*_NODE > HBN_HOSTNAME_NODE* > WORKER_*_NAME"
        exit 1
        ;;
esac
