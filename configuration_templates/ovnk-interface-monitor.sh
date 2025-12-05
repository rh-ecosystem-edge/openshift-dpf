#!/bin/bash

INTERFACE="ovn-k8s-mp0"
CHECK_INTERVAL=30
MIN_CONTAINER_UPTIME=120
OVNKUBE_CONTAINER="ovnkube-controller"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

get_container_id() {
  crictl ps --name $OVNKUBE_CONTAINER -q 2>/dev/null | head -1
}

get_container_uptime() {
  local container_id=$1
  local start_time
  start_time=$(crictl inspect "$container_id" 2>/dev/null | \
    jq -r '.status.startedAt' | \
    xargs -I {} date -d {} +%s 2>/dev/null || echo "0")
  
  if [ -z "$start_time" ] || [ "$start_time" = "0" ]; then
    echo "0"
    return
  fi
  
  echo $(($(date +%s) - start_time))
}

interface_exists() {
  ip link show "$INTERFACE" &>/dev/null
}

restart_ovn_container() {
  local container_id
  container_id=$(get_container_id)
  
  if [ -z "$container_id" ]; then
    log "ERROR: OVN container not found"
    return 1
  fi

  log "Stopping OVN container: $container_id"
  local stop_output
  stop_output=$(crictl stop "$container_id" 2>&1)
  local crictl_exit=$?
  
  if [ $crictl_exit -ne 0 ]; then
    log "ERROR: crictl stop failed (exit $crictl_exit): $stop_output"
    return 1
  fi
  
  log "$stop_output"
  log "Container stopped, kubelet will restart it"
  return 0
}

log "Starting OVN interface monitor for $INTERFACE"

PREV_STATE="unknown"
MISSING_CHECK_COUNT=0

while true; do
  CONTAINER_ID=$(get_container_id)
  
  if [ -z "$CONTAINER_ID" ]; then
    if [ "$PREV_STATE" != "no-container" ]; then
      log "$OVNKUBE_CONTAINER container not running"
      PREV_STATE="no-container"
      MISSING_CHECK_COUNT=0
    fi
    log "Waiting $CHECK_INTERVAL seconds for $OVNKUBE_CONTAINER container to start"
    sleep "$CHECK_INTERVAL"
    continue
  fi
  
  UPTIME=$(get_container_uptime "$CONTAINER_ID")
  
  # Check if interface exists on host
  if interface_exists; then
    if [ "$PREV_STATE" != "present" ]; then
      log "Interface $INTERFACE is present (container uptime: ${UPTIME}s)"
      PREV_STATE="present"
      MISSING_CHECK_COUNT=0
    fi
  else
    MISSING_CHECK_COUNT=$((MISSING_CHECK_COUNT + 1))
    log "WARNING: Interface $INTERFACE missing! (count: $MISSING_CHECK_COUNT, uptime: ${UPTIME}s)"
    
    # Only restart if:
    # 1. Container has been up long enough (not initializing)
    # 2. Missing for 2 consecutive checks (not transient)
    if [ "$UPTIME" -gt "$MIN_CONTAINER_UPTIME" ] && [ "$MISSING_CHECK_COUNT" -ge 2 ]; then
      log "CRITICAL: Interface missing for ${MISSING_CHECK_COUNT} checks, container uptime ${UPTIME}s > ${MIN_CONTAINER_UPTIME}s"
      log "Triggering OVN container restart..."
      
      if restart_ovn_container; then
        # Wait longer after restart before next check
        MISSING_CHECK_COUNT=0
        PREV_STATE="restarting"
        log "Waiting 30s for container to restart and recreate interface..."
        sleep 30
        continue
      fi
    else
      if [ "$UPTIME" -le "$MIN_CONTAINER_UPTIME" ]; then
        log "Container still initializing (${UPTIME}/${MIN_CONTAINER_UPTIME}s), waiting..."
      else
        log "Waiting for second consecutive missing check..."
      fi
    fi
    
    PREV_STATE="missing"
  fi
  
  sleep "$CHECK_INTERVAL"
done
