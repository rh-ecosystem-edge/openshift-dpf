#!/bin/bash
# utils.sh - Common utilities for DPF cluster management

# Exit on error
set -e
set -o pipefail

# Source environment variables
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# -----------------------------------------------------------------------------
# Logging utility
# -----------------------------------------------------------------------------
log() {
    local level=${1:-INFO}
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local script_name=$(basename "$0")

    # Debugging output

    # Skip empty messages
    if [ -z "$message" ]; then
        echo "DEBUG: log function received an empty message, skipping..." >&2
        return
    fi

    case "$level" in
        "INFO")
            echo -e "\033[0;32m[${timestamp}] [${script_name}] [INFO] ${message}\033[0m"
            ;;
        "WARN")
            echo -e "\033[0;33m[${timestamp}] [${script_name}] [WARN] ${message}\033[0m"
            ;;
        "ERROR")
            echo -e "\033[0;31m[${timestamp}] [${script_name}] [ERROR] ${message}\033[0m" >&2
            ;;
        "DEBUG")
            if [ "${DEBUG:-false}" = "true" ]; then
                echo -e "\033[0;36m[${timestamp}] [${script_name}] [DEBUG] ${message}\033[0m"
            fi
            ;;
        *)
            echo -e "[${timestamp}] [${script_name}] [${level}] ${message}"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# File verification functions
# -----------------------------------------------------------------------------
function verify_files() {
    log "INFO" "Verifying required files..."
    
    if [ ! -f "${OPENSHIFT_PULL_SECRET}" ]; then
        log "ERROR" "${OPENSHIFT_PULL_SECRET} not found"
        exit 1
    fi

    if [ ! -f "${DPF_PULL_SECRET}" ]; then
        log "ERROR" "${DPF_PULL_SECRET} not found"
        exit 1
    fi

    if [ ! -f "${HELM_CHARTS_DIR}/ovn-values.yaml" ]; then
        log "ERROR" "${HELM_CHARTS_DIR}/ovn-values.yaml not found"
        exit 1
    fi

    if [ ! -f "${HELM_CHARTS_DIR}/dpf-hcp-bridge-operator-values.yaml" ]; then
        log "ERROR" "${HELM_CHARTS_DIR}/dpf-hcp-bridge-operator-values.yaml not found"
        exit 1
    fi

    log "INFO" "All required files verified successfully"
}

# -----------------------------------------------------------------------------
# Resource waiting functions
# -----------------------------------------------------------------------------
function wait_for_resource() {
    local namespace=$1
    local resource_type=$2
    local resource_name=$3
    local max_attempts=${4:-30}
    local delay=${5:-5}

    log "INFO" "Waiting for $resource_type/$resource_name in namespace $namespace..."

    for i in $(seq 1 "$max_attempts"); do
        if oc get "$resource_type" -n "$namespace" "$resource_name" &>/dev/null; then
            log "INFO" "$resource_type/$resource_name found in namespace $namespace"
            return 0
        fi
        log "INFO" "Waiting for $resource_type/$resource_name (attempt $i/$max_attempts)..."
        sleep "$delay"
    done

    log "ERROR" "Timed out waiting for $resource_type/$resource_name in namespace $namespace"
    return 1
}

function wait_for_secret_with_data() {
    local namespace=$1
    local secret_name=$2
    local key=$3
    local max_attempts=${4:-30}
    local delay=${5:-5}

    log "INFO" "Waiting for secret/$secret_name with valid data for key $key in namespace $namespace..."

    # Use retry to check for secret data existence
    retry "$max_attempts" "$delay" bash -c '
        ns="$1"; secret="$2"; key="$3"
        data=$(oc get secret -n "$ns" "$secret" -o jsonpath="{.data.${key}}" 2>/dev/null)
        [ -n "$data" ]
    ' _ "$namespace" "$secret_name" "$key"
}

function wait_for_pods() {
    local namespace=$1
    local label=$2
    local max_attempts=$3
    local delay=$4

    for i in $(seq 1 "$max_attempts"); do
        # Display pod status (allow this to fail without exiting)
        oc get pods -n "$namespace" -l "$label" 2>&1 || true
        
        # Check if any pods exist with the label
        local pod_count
        pod_count=$(oc get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l)
        
        if [[ "$pod_count" -eq 0 ]]; then
            log "INFO" "No pods found with label $label yet (attempt $i/$max_attempts)..."
            sleep "$delay"
            continue
        fi
        
        # Check if all pods are ready (all containers up and ready)
        # Get Ready condition status for all pods and count "True" values
        local ready_pods
        ready_pods=$(oc get pods -n "$namespace" -l "$label" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l || echo "0")
        
        # Ensure ready_pods is a valid number
        ready_pods=$(echo "$ready_pods" | tr -d '[:space:]')
        [[ -z "$ready_pods" ]] && ready_pods=0
        
        if [[ "$ready_pods" -eq "$pod_count" ]]; then
            log "INFO" "All $pod_count $label pods are ready (all containers running)"
            return 0
        fi
        
        log "INFO" "Waiting for $label pods to be ready: $ready_pods/$pod_count ready (attempt $i/$max_attempts)..."
        sleep "$delay"
    done

    log "ERROR" "$label pods failed to become ready after $max_attempts attempts"
    oc get pods -n "$namespace" -l "$label"
    oc describe pod -n "$namespace" -l "$label"
    exit 1
}

# -----------------------------------------------------------------------------
# Resource checking functions
# -----------------------------------------------------------------------------
function check_namespace_exists() {
    local namespace=$1
    if oc get namespace "$namespace" &>/dev/null; then
        log [INFO] "Namespace $namespace already exists"
        return 0
    fi
    return 1
}

function check_crd_exists() {
    local crd=$1
    if oc get crd "$crd" &>/dev/null; then
        log [INFO] "CRD $crd already exists"
        return 0
    fi
    return 1
}

function check_secret_exists() {
    local namespace=$1
    local secret=$2
    if oc get secret -n "$namespace" "$secret" &>/dev/null; then
        log [INFO] "Secret $secret already exists in namespace $namespace"
        return 0
    fi
    return 1
}

function check_helm_release_exists() {
    local namespace=$1
    local release_name=$2
    if helm list -n "$namespace" 2>/dev/null | grep -q "^${release_name}[[:space:]].*deployed"; then
        log "INFO" "Helm release $release_name already exists in namespace $namespace"
        return 0
    fi
    return 1
}

function check_resource_exists() {
    local file=$1
    local resource_type=$(grep -m 1 "kind:" "$file" | awk '{print $2}')
    local resource_name=$(grep -m 1 "name:" "$file" | awk '{print $2}')
    local namespace=$(grep -m 1 "namespace:" "$file" | awk '{print $2}')
    
    if [ -n "$namespace" ]; then
        if oc get "$resource_type" -n "$namespace" "$resource_name" &>/dev/null; then
            log "INFO" "$resource_type/$resource_name already exists in namespace $namespace."
            return 0
        fi
    else
        if oc get "$resource_type" "$resource_name" &>/dev/null; then
            log "INFO" "$resource_type/$resource_name already exists."
            return 0
        fi
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Manifest application functions
# -----------------------------------------------------------------------------
function apply_manifest() {
    local file=$1
    local apply_always=${2:-false}

    # Skip existence check if apply_always is true
    if [ "$apply_always" != "true" ]; then
        if check_resource_exists "$file"; then
            log "INFO" "Skipping application of $file as it already exists."
            return 0
        fi
    else
        log "INFO" "Applying $file (apply_always=true)..."
    fi
    
    log "INFO" "Applying $file..."
    oc apply -f "$file"
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Failed to apply $file (exit code: $exit_code)"
        return $exit_code
    fi
    return 0
}

function retry() {
    local retries=$1
    local delay=$2
    shift 2
    local attempt=0

    while (( attempt < retries )); do
        if "$@"; then
            return 0
        fi
        attempt=$(( attempt + 1 ))
        echo "Attempt $attempt failed. Retrying in $delay seconds..."
        sleep "$delay"
    done

    echo "All $retries attempts failed."
    return 1
}

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
# Escape string for safe use in sed replacement
escape_sed_replacement() {
    local str="$1"
    # Escape backslashes first, then ampersands, then forward slashes
    printf '%s' "$str" | sed 's/\\/\\\\/g; s/&/\\&/g; s/\//\\\//g'
}

# -----------------------------------------------------------------------------
# Template processing functions
# -----------------------------------------------------------------------------
function process_template() {
    local template_file=$1
    local output_file=$2
    shift 2
    
    log "INFO" "Processing template: $(basename "$template_file")"
    
    # Validate input file exists
    if [ ! -f "$template_file" ]; then
        log "ERROR" "Template file not found: $template_file"
        return 1
    fi
    
    # Ensure output directory exists
    local output_dir=$(dirname "$output_file")
    if [ ! -d "$output_dir" ]; then
        mkdir -p "$output_dir" || {
            log "ERROR" "Failed to create output directory: $output_dir"
            return 1
        }
    fi
    
    # Copy template to output
    cp "$template_file" "$output_file" || {
        log "ERROR" "Failed to copy $template_file to $output_file"
        return 1
    }
    
    # Apply each substitution
    while [ $# -gt 0 ]; do
        local placeholder=$1
        local value=$2
        # Escape the replacement value for sed
        local escaped_value=$(escape_sed_replacement "$value")
        sed -i "s|${placeholder}|${escaped_value}|g" "$output_file"
        log "DEBUG" "Replaced ${placeholder} with ${value} in $(basename "$output_file")"
        shift 2
    done
    
    log "INFO" "Template processed successfully: $(basename "$output_file")"
}

# -----------------------------------------------------------------------------
# File copying and processing functions
# -----------------------------------------------------------------------------

# Function to update a file with multiple replacements
# Uses pure bash string replacement - handles both single-line and multi-line values
update_file_multi_replace() {
    local source_file=$1
    local target_file=$2
    shift 2
    local pairs=("$@")

    log [INFO] "Updating ${source_file} with multiple replacements..."
        
    # Read the entire source file content
    local content
    content=$(<"${source_file}")
    
    local i=0
    while [ $i -lt ${#pairs[@]} ]; do
        local placeholder="${pairs[$i]}"
        local value="${pairs[$((i+1))]}"
        log [INFO] "Replacing ${placeholder} with ${value} in ${target_file}"

        # Use bash parameter expansion for replacement (handles multi-line naturally)
        content="${content//${placeholder}/${value}}"
        
        log [INFO] "Replaced ${placeholder} in ${target_file}"
        i=$((i+2))
    done
    
    # Write the modified content to target file
    printf '%s\n' "${content}" > "${target_file}"
    
    log [INFO] "Updated ${source_file} with all replacements successfully"
}

# Function to check if a file is in an exclusion list
is_file_excluded() {
    local filename=$1
    shift
    local excluded_files=("$@")
    
    for excluded_file in "${excluded_files[@]}"; do
        if [[ "${filename}" == "${excluded_file}" ]]; then
            return 0
        fi
    done
    return 1
}

# Copy manifest files from source to target directory, excluding specified files
# Usage: copy_manifests_with_exclusions SOURCE_DIR TARGET_DIR [EXCLUDED_FILE1 EXCLUDED_FILE2 ...]
copy_manifests_with_exclusions() {
    local source_dir=$1
    local target_dir=$2
    shift 2
    local excluded_files=("$@")
    
    log "INFO" "Copying manifests from $(basename "$source_dir") to $(basename "$target_dir")..."
    
    # Track counts for summary
    
    # Copy all yaml/yml files except excluded ones
    for file in "$source_dir"/*.yaml "$source_dir"/*.yml; do
        # Skip if glob didn't match any files
        [ -f "$file" ] || continue
        
        local filename=$(basename "$file")
        
        if is_file_excluded "$filename" "${excluded_files[@]}"; then
            log "INFO" "Skipping excluded file: ${filename}"
        else
            cp "$file" "$target_dir/" || {
                log "ERROR" "Failed to copy ${filename}"
                return 1
            }
            log "INFO" "Copied manifest: ${filename}"
        fi
    done
    
    log "INFO" "Manifest copy complete"
    return 0
}

# -----------------------------------------------------------------------------
# Cleanup functions
# -----------------------------------------------------------------------------
function clean_resources() {
    log "INFO" "Cleaning up resources..."
    
    # Clean up generated files
    rm -rf "$GENERATED_DIR" || true
    rm -f "kubeconfig.$CLUSTER_NAME" || true
    rm -f "$HOSTED_CLUSTER_NAME.kubeconfig" || true
    rm -f "$KUBECONFIG" || true
    
    log "INFO" "Cleanup complete"
}

generate_mac_from_machine_id() {
    local vm_name="$1"

    # Get machine-id from /etc/machine-id
    if [ ! -f "/etc/machine-id" ]; then
        log "ERROR" "Could not find /etc/machine-id file."
        exit 1
    fi

    local machine_id
    read -r machine_id < /etc/machine-id
    local combined="${machine_id}-${vm_name}"
    local hash
    hash=$(printf "%s" "$combined" | sha256sum | cut -c1-10)

    # Use QEMU's standard locally administered MAC prefix (52:54:00)
    local mac="52:54:00:$(echo "$hash" | sed 's/\(..\)\(..\)\(..\).*/\1:\2:\3/')"

    echo "$mac"
}

# If script is executed directly (not sourced), handle commands
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    command=$1
    case $command in
        verify-files)
            verify_files
            ;;
        *)
            log "ERROR" "Unknown command: $command"
            echo "Available commands: verify-files"
            exit 1
            ;;
    esac
fi 
