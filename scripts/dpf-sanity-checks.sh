#!/bin/bash

# Catch failures in pipelines
set -o pipefail

# color coding for output
RED="\e[31m"
GREEN="\e[32m"
NC="\e[0m"   # No Color


# Defining some variables for this test suite
dpf_operator_namespace="dpf-operator-system"
dpu_enabled_label="feature.node.kubernetes.io/dpu-enabled="

# Load environment variables from .env file (skip if already in Make context)
if [ -z "${MAKELEVEL:-}" ]; then
  echo "Running this script outside of Makefile target, sourcing env.sh file"
  source "$(dirname "$0")/env.sh" 
else
  echo "MAKELEVEL is set to: '${MAKELEVEL}', running this script from a Makefile target"
fi

echo "Checking if the .env file has been previously sourced, and all required variables are set"
if [ -z "${KUBECONFIG}" ]; then
  echo "KUBECONFIG env var is not set, after sourcing env.sh file, exiting ...."
    exit 1
fi

if [ -z "${HOSTED_CLUSTER_NAME}" ]; then
  echo "HOSTED_CLUSTER_NAME env var is not set, after sourcing env.sh file, exiting ...."
    exit 1
fi

if [ -z "${CLUSTER_NAME}" ]; then
  echo "CLUSTER_NAME env var is not set, after sourcing env.sh file, exiting ...."
    exit 1
fi


echo -e "\nVariables from sourced .env file or default values used in the script:"
echo -e "- KUBECONFIG: '${KUBECONFIG}'"
echo -e "- HOSTED_CLUSTER_NAME: '${HOSTED_CLUSTER_NAME}'"
echo -e "- CLUSTER_NAME: '${CLUSTER_NAME}'"
echo -e "- SANITY_TESTS_PODS_WORKLOAD_FILE: '${SANITY_TESTS_PODS_WORKLOAD_FILE}'"
echo -e "- SANITY_TESTS_WORKLOAD_NAMESPACE: '${SANITY_TESTS_WORKLOAD_NAMESPACE}'"
echo -e "- SANITY_TESTS_PING_COUNT: '${SANITY_TESTS_PING_COUNT}'"
echo -e "- SANITY_TESTS_PING_HBN_TO_HBN_PODS: '${SANITY_TESTS_PING_HBN_TO_HBN_PODS}'"
echo -e "- SANITY_TESTS_OVN_ENABLED: '${SANITY_TESTS_OVN_ENABLED}'"
echo -e "- SANITY_TESTS_OVN_NAMESPACE: '${SANITY_TESTS_OVN_NAMESPACE}'"
echo -e "- SANITY_TESTS_OVN_IMAGE: '${SANITY_TESTS_OVN_IMAGE}'"
echo -e "- SANITY_TESTS_OVN_PING_COUNT: '${SANITY_TESTS_OVN_PING_COUNT}'"

mgmt_kubecfg="${KUBECONFIG}"
echo -e "\n- mgmt_kubecfg: '${mgmt_kubecfg}'"

# Get the hosted cluster namespace and kubeconfig secret name via jsonpath
# (avoids column-position issues when VERSION or CP VERSION fields are empty)
hosted_namespace=$(oc get hostedclusters -A --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.items[0].metadata.namespace}')
echo -e "\nExtracted hosted_namespace is: '${hosted_namespace}'"

hosted_kubeconfig_name=$(oc get hostedclusters -A --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.items[0].status.kubeconfig.name}')
echo -e "\nExtracted hosted_kubeconfig_name is: '${hosted_kubeconfig_name}'"

if [ -z "${hosted_namespace}" ] || [ -z "${hosted_kubeconfig_name}" ]; then
  echo "ERROR: Failed to extract hosted cluster namespace or kubeconfig secret name"
  oc get hostedclusters -A --kubeconfig="${mgmt_kubecfg}" || true
  exit 1
fi

datetime_string=$(date +"%Y-%m-%d_%H-%M-%S")
echo -e "\nTimestamp prefix used in this script: '${datetime_string}'"

echo "Currrent working directory: $PWD"

# build path to hosted cluster kubeconfig file
hosted_kubecfg="${PWD}/${HOSTED_CLUSTER_NAME}-kubeconfig-${datetime_string}"
echo -e "\nhosted_kubecfg file path: '${hosted_kubecfg}'"

echo -e "\nExtracting the hosted cluster '${HOSTED_CLUSTER_NAME}' kubeconfig '${hosted_kubeconfig_name}' to a file named '${hosted_kubecfg}'"
oc get secret -n "${hosted_namespace}" "${hosted_kubeconfig_name}" --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.data.kubeconfig}' | base64 -d > "${hosted_kubecfg}"

# check if the hosted cluster kubeconfig file was created successfully and is not empty
if [ -s "${hosted_kubecfg}" ]; then
  echo -e "\nhosted_kubecfg file was created successfully at path: '${hosted_kubecfg}'"
else
  echo -e "\nFailed to create hosted cluster kubeconfig file '${hosted_kubecfg}' (missing or empty)"
  exit 1
fi

echo -e "\nOutput of oc get nodes --kubeconfig='${mgmt_kubecfg}':"
oc get nodes --kubeconfig="${mgmt_kubecfg}"

# Find number of DPU enabled host worker nodes which are in Ready state on management cluster
dpu_host_worker_list=$(oc get nodes --no-headers -l ${dpu_enabled_label}  --kubeconfig="${mgmt_kubecfg}" | awk '$2=="Ready" && $3=="worker,worker-dpu" {print $1}' | xargs)

echo -e "\nChecking how many DPU enabled host worker nodes are in Ready Phase on management cluster"
if [ -z "${dpu_host_worker_list}" ]; then
  echo "No DPU enabled host worker nodes found in Ready Phase on management cluster"
  exit 1
fi

# declare empty array
dpu_host_workers=()

dpu_host_worker_count=0

for i in $dpu_host_worker_list ; do
  dpu_host_workers[${dpu_host_worker_count}]=$i
  echo "DPU host Worker node '${dpu_host_workers[${dpu_host_worker_count}]}' is Ready";
  ((dpu_host_worker_count++))
done

echo "Detected ${dpu_host_worker_count} DPU host workers in Ready phase"
echo -e "Working with ${dpu_host_worker_count} DPU host worker nodes: '${dpu_host_workers[*]}'"

# Find number of DPU worker nodes which are ready
echo -e "\nOutput of oc get nodes --kubeconfig='${hosted_kubecfg}':"
oc get nodes --kubeconfig="${hosted_kubecfg}"

get_dpu_output=$(oc get dpu -n ${dpf_operator_namespace} --kubeconfig=${mgmt_kubecfg})
echo -e "Output of oc get dpu:\n${get_dpu_output}"

# Note worker node names may not have .com and FQDN anymore, this is mainly for the kubernetes network flow tests
dpu_worker_list=$(oc get nodes --no-headers --kubeconfig="${hosted_kubecfg}" | awk '$2=="Ready" && $3=="worker" {print $1}' | xargs)

echo -e "\nChecking how many DPU worker nodes are in Ready Phase on management cluster"
if [ -z "${dpu_worker_list}" ]; then
  echo "No DPU worker nodes found in Ready Phase on hosted cluster"
  exit 1
fi  

# declare empty array
dpu_workers=()

dpu_worker_count=0

for i in $dpu_worker_list ; do 
  dpu_workers[${dpu_worker_count}]=$i
  echo "Worker node '${dpu_workers[${dpu_worker_count}]}' is Ready";
  ((dpu_worker_count++))
done

echo "Detected ${dpu_worker_count} DPU workers in Ready phase"
echo -e "Working with ${dpu_worker_count} DPU worker nodes: '${dpu_workers[*]}'"


# counter to track number of failed test cases
failed_testcase_count=0

# counter to track total testcases
total_testcases_executed=0

# variable to store test_results summary
test_results_summary="Test Results Summary:
---------------------"

# Function to run on error
error_handler() {
    echo "Script exited with error!"
    echo "❌ Error on command:  '${BASH_COMMAND}' exited with status $?"
    echo -e "Test results so far: \n${test_results_summary}"
    echo -e "\nTotal of testcases executed: ${total_testcases_executed}"
    echo -e "Number of failed tests: ${failed_testcase_count}" 
}

# Trap ERR signal
trap error_handler ERR

ovn_tests_deployed=false

ovn_cleanup() {
    if [ "${ovn_tests_deployed}" = "true" ]; then
        echo -e "\nCleaning up OVN test resources in namespace '${SANITY_TESTS_OVN_NAMESPACE}'..."
        oc delete namespace "${SANITY_TESTS_OVN_NAMESPACE}" --timeout=60s --kubeconfig="${mgmt_kubecfg}" 2>/dev/null || true
        rm -f "${ovn_manifest_generated:-}" "${ovn_crossnode_manifest_generated:-}" 2>/dev/null || true
    fi
}

trap ovn_cleanup EXIT

check_deployments_ready() {
  local namespace="$1"
  local kubeconfig="$2"

  oc get deployment -n "$namespace" --kubeconfig="$kubeconfig" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.readyReplicas}{" "}{.spec.replicas}{"\n"}{end}' \
  | awk '
  {
      ready = ($2 == "") ? 0 : $2
      desired = $3

      if (ready != desired) {
          print "Deployment " $1 " NOT READY (" ready "/" desired ")"
          failed = 1
      } else {
          print "Deployment " $1 " ready (" ready "/" desired ")"
      }
  }
  END {
      exit failed
  }'
}

# Function to parse output of ping cmd and report packet loss
check_ping_packet_loss() {
  # output is in first argument
  output=$1

  # increment the total testcase executed counter
  ((total_testcases_executed++))

  # check if output argument exists or is empty 
  if [ -z "${output}" ]; then
    echo "Usage: check_ping_packet_loss <PING_OUTPUT>"
    exit 1
  fi

  # Extract packet loss
  PACKET_LOSS=$(echo "${output}" | grep -Eo '[0-9]+% packet loss' | awk '{print $1}' | tr -d '%')

  if [ -z "$PACKET_LOSS" ]; then
    echo "Failed to extract packet loss from ping output"
    echo "Fail"
    ((failed_testcase_count++))
    return 1
  fi

  if [ "$PACKET_LOSS" -eq 0 ]; then
      echo "Packet loss percent is: ${PACKET_LOSS}"
      echo -e "${GREEN}Pass${NC}"
      return 0
  else
      echo "Packet loss percent is: ${PACKET_LOSS}, not 0"
      echo -e "${RED}Fail${NC}"
      # increment the failed testcase counter
      ((failed_testcase_count++))
      return 1
  fi
}

# function to translate results
format_result() {
  local result="$1"

  # Check if result is an integer
  if ! [[ "$result" =~ ^[0-9]+$ ]]; then
    echo "Invalid input: not a number"
    return 1
  fi

  if [ "$result" -eq 0 ]; then
    echo -e "${GREEN}Pass${NC}"
  else
    echo -e "${RED}Fail${NC}"
  fi
}

# Function to find degraded or progressing cluster operators and report status condition
check_cluster_operators() {
  local kubeconfig="$1"   # Optional: pass kubeconfig path
  local oc_cmd="oc"

  # if $kubeconfig string length is > 0 then add it to the --kubeconfig switch
  [[ -n "$kubeconfig" ]] && oc_cmd="oc --kubeconfig=${kubeconfig}"


  # If none found, print a healthy message
  if ! $oc_cmd get co -o json | jq -e '.items[] | .status.conditions[] | select((.type=="Degraded" or .type=="Progressing") and .status=="True")' >/dev/null; then
    echo "✅ No operators are Degraded or Progressing."
    return 0
  else
    ((failed_testcase_count++))
    # Header
    printf "%-25s %-12s %-s\n" "OPERATOR" "STATUS" "MESSAGE"
    printf "%-25s %-12s %-s\n" "--------" "------" "-------"

    # Get cluster operators JSON and parse
    $oc_cmd get co -o json | jq -r '
      .items[] as $op |
      $op.status.conditions[] |
      select((.type=="Degraded" or .type=="Progressing") and .status=="True") |
      [$op.metadata.name, .type, .message] | @tsv
    ' | while IFS=$'\t' read -r name type msg; do
      printf "%-25s %-12s %-s\n" "$name" "$type" "$msg"
      done
    return 1
  fi
}

# Function to perform the ping test with arguments
ping_mtu_test() {
  tc_title=$1
  source_pod=$2
  namespace=$3
  kubecfg=$4
  ping_count=$5
  ping_mtu=$6
  destination_ip=$7

  # optional 8th argument to specify container name in pod
  container_name=""
  # [ -n "$8" ] && container_name="-c $8"

  if [ -n "$8" ]; then
    container_name="$8"
    testcase_pre_cmd="oc exec ${source_pod} -n $namespace --kubeconfig=${kubecfg} -c ${container_name}"
  else
    testcase_pre_cmd="oc exec ${source_pod} -n $namespace --kubeconfig=${kubecfg}"
  fi

  if [ "$ping_mtu" = "normal" ]; then
    # testcase_cmd="oc exec ${source_pod} -n $namespace --kubeconfig=${kubecfg} ${container_name} -- ping -c ${ping_count} ${destination_ip}"
    testcase_cmd="${testcase_pre_cmd} -- ping -c ${ping_count} ${destination_ip}"
  else
    testcase_cmd="${testcase_pre_cmd} -- ping -c ${ping_count} -M do -s ${ping_mtu} ${destination_ip}"
  fi

  echo -e "\n${tc_title}:\n${testcase_cmd}"

  testcase_output=$(eval ${testcase_cmd})

  echo -e "${testcase_output}"

  check_ping_packet_loss "${testcase_output}"
  testcase_result=$?
  echo -e "tescase_result is: ${testcase_result}"

  test_results_summary+="\n${tc_title}: $(format_result "${testcase_result}")"
}

check_dpuservices_ready() {
  local kubeconfig="$1"
  local bad_dpusvc=()

  while IFS=$'\t' read -r name ready; do
    [ -z "$name" ] && continue
    if [ "$ready" != "True" ]; then
      bad_dpusvc+=("$name")
    fi
  done < <(oc get dpuservice -n "${dpf_operator_namespace}" --kubeconfig="${kubeconfig}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null)

  if [ ${#bad_dpusvc[@]} -eq 0 ]; then
    echo -e "${GREEN}Pass${NC} All DPUServices are ready"
    return 0
  else
    echo -e "${RED}Fail${NC} DPUServices not ready: ${bad_dpusvc[*]}"
    ((failed_testcase_count++))
    return 1
  fi
}

check_doca_ovn_pods() {
  local kubeconfig="$1"
  local ovn_pods bad_ovn=()

  ovn_pods=$(oc get pods -n "${dpf_operator_namespace}" \
    -l app.kubernetes.io/component=ovnkube-node \
    --kubeconfig="${kubeconfig}" --no-headers 2>/dev/null)

  if [ -z "$ovn_pods" ]; then
    echo -e "${RED}Fail${NC} No DOCA OVN pods found in hosted cluster"
    ((failed_testcase_count++))
    return 1
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name ready status
    name=$(awk '{print $1}' <<<"$line")
    ready=$(awk '{print $2}' <<<"$line")
    status=$(awk '{print $3}' <<<"$line")
    if [ "$ready" != "8/8" ] || [ "$status" != "Running" ]; then
      bad_ovn+=("$name ($ready $status)")
    fi
  done <<<"$ovn_pods"

  if [ ${#bad_ovn[@]} -eq 0 ]; then
    echo -e "${GREEN}Pass${NC} All DOCA OVN pods are 8/8 Running"
    return 0
  else
    echo -e "${RED}Fail${NC} DOCA OVN pods not healthy: ${bad_ovn[*]}"
    ((failed_testcase_count++))
    return 1
  fi
}

check_hbn_bgp_neighbors() {
  local kubeconfig="$1"
  local hbn_pods bgp_result=0

  hbn_pods=$(oc get pods -n "${dpf_operator_namespace}" \
    -l app.kubernetes.io/name=hbn \
    --kubeconfig="${kubeconfig}" --no-headers 2>/dev/null)

  if [ -z "$hbn_pods" ]; then
    echo -e "${RED}Fail${NC} No HBN pods found in hosted cluster"
    ((failed_testcase_count++))
    return 1
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local pod bgp_out
    pod=$(awk '{print $1}' <<<"$line")

    bgp_out=$(oc exec -n "${dpf_operator_namespace}" "${pod}" -c doca-hbn \
      --kubeconfig="${kubeconfig}" -- nv show vrf default router bgp neighbor 2>/dev/null) || true

    if [ -z "$bgp_out" ]; then
      echo -e "${RED}Fail${NC} HBN BGP: no neighbors on ${pod}"
      bgp_result=1
    else
      local all_states total_neighbors not_established
      all_states=$(awk '/^---/{found=1; next} found && NF>2{print $3}' <<<"$bgp_out" | grep -iE 'established|idle|connect|active|opensent|openconfirm') || true
      total_neighbors=$(echo "$all_states" | grep -c . 2>/dev/null) || true
      not_established=$(echo "$all_states" | grep -ivw 'established' | grep -c . 2>/dev/null) || true

      if [ "${total_neighbors:-0}" -eq 0 ]; then
        echo -e "${RED}Fail${NC} HBN BGP: no neighbors parsed on ${pod}"
        bgp_result=1
      elif [ "${not_established}" -eq 0 ]; then
        echo -e "${GREEN}Pass${NC} HBN BGP: all ${total_neighbors} neighbor(s) established on ${pod}"
      else
        local bad_states
        bad_states=$(echo "$all_states" | grep -ivw 'established' | paste -sd, -) || true
        echo -e "${RED}Fail${NC} HBN BGP: ${not_established}/${total_neighbors} neighbor(s) not established on ${pod} (${bad_states})"
        bgp_result=1
      fi
    fi
  done <<<"$hbn_pods"

  if [ "$bgp_result" -ne 0 ]; then
    ((failed_testcase_count++))
  fi
  return $bgp_result
}

ovn_curl_test() {
  local tc_title="$1"
  local source_pod="$2"
  local url="$3"

  ((total_testcases_executed++))

  echo -e "\n${tc_title}"
  local testcase_cmd="oc exec ${source_pod} -n ${SANITY_TESTS_OVN_NAMESPACE} --kubeconfig=${mgmt_kubecfg} -- curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 ${url}"
  echo -e "${testcase_cmd}"

  local code
  code=$(eval ${testcase_cmd} 2>/dev/null) || true

  local testcase_result
  if [ "$code" = "200" ]; then
    echo -e "HTTP status: ${code}"
    echo -e "${GREEN}Pass${NC}"
    testcase_result=0
  else
    echo -e "HTTP status: ${code:-no-response}"
    echo -e "${RED}Fail${NC}"
    ((failed_testcase_count++))
    testcase_result=1
  fi

  test_results_summary+="\n${tc_title}: $(format_result "${testcase_result}")"
}

# output of `oc get co` on management cluster
echo -e "\nOutput of oc get co cmd on mgmt cluster:"
oc get co --kubeconfig=${mgmt_kubecfg}

testcase_title="Checking if any cluster operators are degraded or progressing on management cluster" 
echo -e "\n${testcase_title}"

# increment to the total testcases executed
((total_testcases_executed++))

check_cluster_operators "${mgmt_kubecfg}"
result_check_cluster_operators=$?
test_results_summary+="\n${testcase_title}: $(format_result "${result_check_cluster_operators}")"

# output of `oc get co` on hosted cluster:
echo -e "\nOutput of oc get co cmd on hosted cluster:"
oc get co --kubeconfig=${hosted_kubecfg} 

testcase_title="Checking if any cluster operators are degraded or progressing on hosted cluster" 
echo -e "\n${testcase_title}"

# increment to the total testcases executed
((total_testcases_executed++))

check_cluster_operators "${hosted_kubecfg}"
result_check_cluster_operators=$?
test_results_summary+="\n${testcase_title}: $(format_result "${result_check_cluster_operators}")"

testcase_title="Checking if all DPUServices are ready"
echo -e "\n${testcase_title}"
((total_testcases_executed++))
check_dpuservices_ready "${mgmt_kubecfg}"
result_check_dpuservices=$?
test_results_summary+="\n${testcase_title}: $(format_result "${result_check_dpuservices}")"

testcase_title="Checking DOCA OVN pods are 8/8 Running on hosted cluster"
echo -e "\n${testcase_title}"
((total_testcases_executed++))
check_doca_ovn_pods "${hosted_kubecfg}"
result_check_ovn_pods=$?
test_results_summary+="\n${testcase_title}: $(format_result "${result_check_ovn_pods}")"

testcase_title="Checking HBN BGP neighbors are established on hosted cluster"
echo -e "\n${testcase_title}"
((total_testcases_executed++))
check_hbn_bgp_neighbors "${hosted_kubecfg}"
result_check_bgp=$?
test_results_summary+="\n${testcase_title}: $(format_result "${result_check_bgp}")"

echo -e "\nChecking if workload namespace exists on admin cluster, otherwise create it"
if oc get namespace "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" >/dev/null 2>&1; then
  echo "✅ Namespace '${SANITY_TESTS_WORKLOAD_NAMESPACE}' exists."
  echo -e "Checking if workload sriov test pods have already been deployed on admin cluster" 
else
  echo "❌ Namespace '${SANITY_TESTS_WORKLOAD_NAMESPACE}' does NOT exist."
  echo "Creating namespace '${SANITY_TESTS_WORKLOAD_NAMESPACE}' and applying the yaml file '${SANITY_TESTS_PODS_WORKLOAD_FILE}'"

  # Note: the workload.yaml file also creates the workload namesace and resources it needs
  if oc apply -f "${SANITY_TESTS_PODS_WORKLOAD_FILE}" --kubeconfig="${mgmt_kubecfg}" >/dev/null 2>&1; then
    echo "✅ Namespace '${SANITY_TESTS_WORKLOAD_NAMESPACE}' and workload.yaml file applied successfully."

    echo "Waiting up to 5 mins for deployments to be ready..."
    oc wait --for=condition=available --timeout=300s \
      deployment --all -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" \
      --kubeconfig="${mgmt_kubecfg}"

  else
    echo "❌ Failed to create namespace '${SANITY_TESTS_WORKLOAD_NAMESPACE}' and applying '${SANITY_TESTS_PODS_WORKLOAD_FILE}' file."
    exit 1
  fi
fi

# Check that all the pods are running in the '${SANITY_TESTS_WORKLOAD_NAMESPACE}' namespace, otherwise exit:
testcase_title="Check that all the pods are running in the '${SANITY_TESTS_WORKLOAD_NAMESPACE}' namespace"
echo -e "\n${testcase_title}, otherwise exit script..."

check_deployments_ready "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}"
result_check_deployments_ready=$?
test_results_summary+="\n${testcase_title}: $(format_result "${result_check_deployments_ready}")"

echo -e "\noc get nodes --kubeconfig=${mgmt_kubecfg} output:"
oc get nodes --kubeconfig=${mgmt_kubecfg}

echo -e "\noc get nodes --kubeconfig=${hosted_kubecfg} output:"
oc get nodes --kubeconfig=${hosted_kubecfg}

echo -e "\noc get pods -n ${dpf_operator_namespace} --kubeconfig=${mgmt_kubecfg} -o wide output:"
oc get pods -n ${dpf_operator_namespace} --kubeconfig="${mgmt_kubecfg}" -o wide

# Find doca-hbn-pod names on each DPU worker node
echo -e "\noc get pods -n ${dpf_operator_namespace} --kubeconfig=${hosted_kubecfg} -o wide output:"
oc get pods -n ${dpf_operator_namespace} --kubeconfig="${hosted_kubecfg}" -o wide

# declare array doca_hbn_worker_pods[]
doca_hbn_worker_pods=()

for i in "${!dpu_workers[@]}"; do
  echo -e "\nFinding doca hbn pod name for DPU worker '${dpu_workers[$i]}'"
  doca_hbn_worker_pods[$i]=$(oc get pods -n "${dpf_operator_namespace}" --kubeconfig="${hosted_kubecfg}" -o wide | grep "${dpu_workers[$i]}" | grep "\-hbn\-" | awk '{print $1}')
  echo -e "doca-hbn pod for worker '${dpu_workers[$i]}' found was: '${doca_hbn_worker_pods[$i]}'"
  
  # check that doca-hbn pod was found, otherwise exit
  if [ -z "${doca_hbn_worker_pods[$i]}" ]; then
    echo -e "❌ Failed to find doca-hbn pod for DPU worker '${dpu_workers[$i]}'"
    exit 1
  else
    echo -e "✅ Found doca-hbn pod for DPU worker '${dpu_workers[$i]}' is: '${doca_hbn_worker_pods[$i]}'"
  fi  
done

echo -e "\nGetting the doca-hbn container ip address for all the DPU worker nodes"

# declare array doca_hbn_worker_pod_ip[]
doca_hbn_worker_pod_ip=()

for i in "${!dpu_workers[@]}"; do
  # Find the doca hbn pod ip address for dpu_workers array index $i '${dpu_workers[$i]}' for doca-hbn pod name '${doca_hbn_worker_pods[$i]}'"
  doca_hbn_worker_pod_ip[$i]=$(oc exec "${doca_hbn_worker_pods[$i]}" -n "${dpf_operator_namespace}"  --kubeconfig="${hosted_kubecfg}" -c doca-hbn -- ip a show pf2dpu2_if | grep "inet " | awk '{print $2}' | cut -d'/' -f1)

  # check that ip address was found
  if [ -z "${doca_hbn_worker_pod_ip[$i]}" ]; then
    echo -e "❌ Failed to find ip address for doca-hbn pod '${doca_hbn_worker_pods[$i]}' on DPU worker node '${dpu_workers[$i]}'"
    exit 1
  else
    echo -e "✅ Found ip address for doca-hbn pod '${doca_hbn_worker_pods[$i]}' on DPU worker node '${dpu_workers[$i]}' is:  '${doca_hbn_worker_pod_ip[$i]}'"
  fi
done

output_workload_namespace=$(oc get pods -n  ${SANITY_TESTS_WORKLOAD_NAMESPACE} --kubeconfig=${mgmt_kubecfg} -o wide)

echo -e "\nOutput of oc get pods -n ${SANITY_TESTS_WORKLOAD_NAMESPACE}: \n$output_workload_namespace\n"

sriov_test_pod_master=$(oc get pods -n ${SANITY_TESTS_WORKLOAD_NAMESPACE} --kubeconfig="${mgmt_kubecfg}" | grep master | awk '{print $1}')

# check that sriov master test pod was found, and running 
if [ -z "${sriov_test_pod_master}" ]; then
  echo -e "❌ Failed to find sriov master test pod"
  exit 1
else
  echo -e "✅ Found sriov master test pod is: '${sriov_test_pod_master}'"

  if [ "$(oc get pods -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" | grep "${sriov_test_pod_master}" | awk '{print $3}')" != "Running" ]; then
      echo -e "❌ Sriov master test pod '${sriov_test_pod_master}' is not running, failing test ..."
      exit 1
  else
    echo -e "✅ Sriov master test pod '${sriov_test_pod_master}' is running"
  fi
fi

# get the test worker pod names on DPU worker node
echo -e "\nGetting the sriov test worker pods on all the DPU worker nodes"

# declare array sriov_test_worker_pods[]
sriov_test_worker_pods=()

# declare array sriov_test_worker_pods_hostnetwork[]
sriov_test_worker_pods_hostnetwork=()

echo -e "\nRunning ping tests on all the DPU worker nodes ..."

#------------  Loop throug each dpu worker node 
for i in "${!dpu_host_workers[@]}"; do

  testcase_title="Test pings from sriov master test pod '${sriov_test_pod_master}' to doca-hbn pod '${doca_hbn_worker_pods[$i]}' on node '${dpu_host_workers[$i]}'"
  ping_mtu_test "${testcase_title}" "${sriov_test_pod_master}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 1490 "${doca_hbn_worker_pod_ip[$i]}"

  echo -e "\nFinding sriov test worker pod name for dpu_host_workers array index $i '${dpu_host_workers[$i]}' to ping doca-hbn pod name '${doca_hbn_worker_pods[$i]}'"
  sriov_test_worker_pods[$i]=$(oc get pods -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o wide | grep "${dpu_host_workers[$i]}" | grep "Running" | awk '{print $1}' | grep -v hostnetwork | head -1)

  if [ -z "${sriov_test_worker_pods[$i]}" ]; then
    echo -e "❌ Failed to find sriov test worker pod for DPU worker '${dpu_host_workers[$i]}'. Exiting script..."
    exit 1
  else
    echo -e "✅ Found sriov test worker pod for DPU worker '${dpu_host_workers[$i]}': '${sriov_test_worker_pods[$i]}'"

    # check if the sriov test worker pod is running, if not Running, fail test ...
    if [ "$(oc get pod "${sriov_test_worker_pods[$i]}" -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.status.phase}')" != "Running" ]; then
      echo -e "❌ Test pod '${sriov_test_worker_pods[$i]}' is not running, Exiting script..."
      exit 1
    else 
      echo -e "✅ Test pod '${sriov_test_worker_pods[$i]}' is running"
    fi
  fi

  echo -e "\nFinding sriov_test_workers_pods_hostnetwork name for dpu_host_workers array index $i '${dpu_host_workers[$i]}' to ping doca-hbn pod name '${doca_hbn_worker_pods[$i]}'"
  sriov_test_worker_pods_hostnetwork[$i]=$(oc get pods -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o wide | grep "${dpu_host_workers[$i]}" | awk '{print $1}' | grep hostnetwork | head -1)
  if [ -z "${sriov_test_worker_pods_hostnetwork[$i]}" ]; then
    echo -e "❌ Failed to find sriov test worker hostnetwork pod for DPU worker '${dpu_host_workers[$i]}'. Exiting script..."
    exit 1
  else
    echo -e "✅ Found sriov test worker hostnetwork pod for DPU worker '${dpu_host_workers[$i]}': '${sriov_test_worker_pods_hostnetwork[$i]}'"
    # check if the sriov test worker hostnetwork pod is running, if not Running, fail test ...
    if [ "$(oc get pod "${sriov_test_worker_pods_hostnetwork[$i]}" -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.status.phase}')" != "Running" ]; then
      echo -e "❌ Test pod '${sriov_test_worker_pods_hostnetwork[$i]}' is not running, Exiting script..."
      exit 1
    else 
      echo -e "✅ Test pod '${sriov_test_worker_pods_hostnetwork[$i]}' is running"
    fi
  fi

  echo -e "\nList of interfaces that are up on doca-hbn pod '${doca_hbn_worker_pods[$i]}' for DPU host worker '${dpu_host_workers[$i]}':"
  oc exec "${doca_hbn_worker_pods[$i]}" -n "${dpf_operator_namespace}"  --kubeconfig="${hosted_kubecfg}" -c doca-hbn -- ip -4 -o a

  doca_hbn_worker_pod_ip[$i]=$(oc exec "${doca_hbn_worker_pods[$i]}" -n "${dpf_operator_namespace}"  --kubeconfig="${hosted_kubecfg}" -c doca-hbn -- ip a show pf2dpu2_if | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
  echo -e "doca-hbn pod ip address for DPU worker '${dpu_workers[$i]}' is: '${doca_hbn_worker_pod_ip[$i]}'"

  # Test pings from sriov test-worker pod on worker node i:
  testcase_title="Test pings mtu 1490 from sriov worker test pod '${sriov_test_worker_pods[$i]}' to doca-hbn pod ip '${doca_hbn_worker_pod_ip[$i]}' on DPU worker '${dpu_workers[$i]}'"
  ping_mtu_test "$testcase_title" "${sriov_test_worker_pods[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 1490 "${doca_hbn_worker_pod_ip[$i]}"

  # Test pings mtu 1490 from sriov test-worker hostnetwork pod on worker node i:
  ## testcase_title="Test pings mtu 1490 from sriov worker test pod on hostnetwork '${sriov_test_worker_pods_hostnetwork[$i]}' to doca-hbn pod ip '${doca_hbn_worker_pod_ip[$i]}' on DPU worker '${dpu_workers[$i]}'"
  ## ping_mtu_test "$testcase_title" "${sriov_test_worker_pods_hostnetwork[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 1490 "${doca_hbn_worker_pod_ip[$i]}"

  # Test pings mtu 8970 from sriov test-worker hostnetwork pod on worker node i:
  ## testcase_title="Test pings mtu 8970 from sriov worker test pod on hostnetwork '${sriov_test_worker_pods_hostnetwork[$i]}' to doca-hbn pod ip '${doca_hbn_worker_pod_ip[$i]}' on  DPU Worker '${dpu_workers[$i]}'"
  ## ping_mtu_test "$testcase_title" "${sriov_test_worker_pods_hostnetwork[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 8970 "${doca_hbn_worker_pod_ip[$i]}"

  #----------  ping google.com on worker node i
  # Test pings from sriov test-worker pod on worker node i to 8.8.8.8 google.com:
  testcase_title="Test pings from sriov worker test pod '${sriov_test_worker_pods[$i]}' to 8.8.8.8 google.com on DPU host worker '${dpu_host_workers[$i]}'"
  ping_mtu_test "$testcase_title" "${sriov_test_worker_pods[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" normal "8.8.8.8"

  # Test pings from sriov test-worker hostnetwork pod on worker node i to 8.8.8.8 google.com:
  testcase_title="Test pings from sriov worker test pod on hostnetwork '${sriov_test_worker_pods_hostnetwork[$i]}' to 8.8.8.8 google.com on DPU host worker '${dpu_host_workers[$i]}'"
  ping_mtu_test "$testcase_title" "${sriov_test_worker_pods_hostnetwork[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" "normal" "8.8.8.8"

done

echo -e "\nChecking if SANITY_TESTS_PING_HBN_TO_HBN_PODS flag is set to 'true' before attempting to run the ping tests between the doca-hbn pods"

# Ping between doca-hbn pods is now optional
if [ "${SANITY_TESTS_PING_HBN_TO_HBN_PODS}" == "true" ]; then
  echo -e "Flag 'SANITY_TESTS_PING_HBN_TO_HBN_PODS' is set to 'true'"

  echo -e "Checking if DPU worker count is 2.  Number of DPU workers in this test suite: ${dpu_worker_count}"

  if [ "${dpu_worker_count}" -eq 2 ]; then

    echo -e "DPU worker count is 2.  Running ping tests between the two doca hbn pods on two 2 DPU workers nodes"

    # Test pings mtu 1490 from doca-hbn pod on worker node 1 to doca-hbn pod on worker node 2:
    testcase_title="Test pings mtu 1490 from doca-hbn pod '${doca_hbn_worker_pods[0]}' on DPU worker '${dpu_workers[0]}' to '${doca_hbn_worker_pods[1]}' on DPU worker '${dpu_workers[1]}'"
    ping_mtu_test "$testcase_title" "${doca_hbn_worker_pods[0]}" "${dpf_operator_namespace}" "${hosted_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 1490 "${doca_hbn_worker_pod_ip[1]}" "doca-hbn"

    # Test pings mtu 8970 from doca-hbn pod on worker node 1 to doca-hbn pod on worker node 2:
    testcase_title="Test pings mtu 8970 from doca-hbn pod '${doca_hbn_worker_pods[0]}' on DPU worker '${dpu_workers[0]}' to '${doca_hbn_worker_pods[1]}' on DPU worker '${dpu_workers[1]}'"
    ping_mtu_test "$testcase_title" "${doca_hbn_worker_pods[0]}" "${dpf_operator_namespace}" "${hosted_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 8970 "${doca_hbn_worker_pod_ip[1]}" "doca-hbn"

    # Test pings mtu 1490 from doca-hbn pod on worker node 2 to doca-hbn pod on worker node 1:
    testcase_title="Test pings mtu 1490 from doca-hbn pod '${doca_hbn_worker_pods[1]}' on DPU worker '${dpu_workers[1]}' to '${doca_hbn_worker_pods[0]}' on DPU worker '${dpu_workers[0]}'"
    ping_mtu_test "$testcase_title" "${doca_hbn_worker_pods[1]}" "${dpf_operator_namespace}" "${hosted_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 1490 "${doca_hbn_worker_pod_ip[0]}" "doca-hbn"

    # Test pings mtu 8970 from doca-hbn pod on worker node 2 to doca-hbn pod on worker node 1:
    testcase_title="Test pings mtu 8970 from doca-hbn pod '${doca_hbn_worker_pods[1]}' on DPU worker '${dpu_workers[1]}' to '${doca_hbn_worker_pods[0]}' on DPU worker '${dpu_workers[0]}'"
    ping_mtu_test "$testcase_title" "${doca_hbn_worker_pods[1]}" "${dpf_operator_namespace}" "${hosted_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 8970 "${doca_hbn_worker_pod_ip[0]}" "doca-hbn"

  else
    echo -e "DPU worker count is not 2:  ${dpu_worker_count}.  Skipping ping test between the two doca hbn pods"

  fi

else 
   echo -e "Flag 'SANITY_TESTS_PING_HBN_TO_HBN_PODS' is set to '${SANITY_TESTS_PING_HBN_TO_HBN_PODS}'.  Skipping ping tests between doca-hbn pods across DPU worker nodes" 

fi

# ═══════════════════════════════════════════════════════════════════════
# OVN Connectivity Tests
# ═══════════════════════════════════════════════════════════════════════
echo -e "\nChecking if SANITY_TESTS_OVN_ENABLED flag is set to 'true'"

if [ "${SANITY_TESTS_OVN_ENABLED}" != "true" ]; then
  echo -e "SANITY_TESTS_OVN_ENABLED is '${SANITY_TESTS_OVN_ENABLED}'. Skipping OVN connectivity tests."
else
  echo -e "SANITY_TESTS_OVN_ENABLED is 'true'. Running OVN connectivity tests.\n"

  ovn_cp_node=$(oc get nodes -l node-role.kubernetes.io/control-plane \
    --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [ -z "${ovn_cp_node}" ]; then
    echo "No control-plane node found for OVN tests"
    exit 1
  fi
  echo -e "Control-plane node for OVN tests: '${ovn_cp_node}'"

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ovn_manifests_dir="${script_dir}/../manifests/testing"

  ovn_manifest_generated="${PWD}/ovn-test-pods-${datetime_string}.yaml"
  cp "${ovn_manifests_dir}/ovn-test-pods.yaml" "${ovn_manifest_generated}"
  sed -i "s|<OVN_TEST_NAMESPACE>|${SANITY_TESTS_OVN_NAMESPACE}|g" "${ovn_manifest_generated}"
  sed -i "s|<OVN_TEST_NODE1>|${dpu_host_workers[0]}|g" "${ovn_manifest_generated}"
  sed -i "s|<OVN_TEST_CP_NODE>|${ovn_cp_node}|g" "${ovn_manifest_generated}"
  sed -i "s|<OVN_TEST_IMAGE>|${SANITY_TESTS_OVN_IMAGE}|g" "${ovn_manifest_generated}"

  if oc get namespace "${SANITY_TESTS_OVN_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" >/dev/null 2>&1; then
    echo "Pre-existing OVN test namespace '${SANITY_TESTS_OVN_NAMESPACE}' found, cleaning up..."
    oc delete namespace "${SANITY_TESTS_OVN_NAMESPACE}" --timeout=60s --kubeconfig="${mgmt_kubecfg}" || true
    oc wait --for=delete namespace/"${SANITY_TESTS_OVN_NAMESPACE}" \
      --timeout=60s --kubeconfig="${mgmt_kubecfg}" 2>/dev/null || true
  fi

  echo -e "\nApplying OVN test manifest: '${ovn_manifest_generated}'"
  oc apply -f "${ovn_manifest_generated}" --kubeconfig="${mgmt_kubecfg}"

  ovn_crossnode_manifest_generated=""
  if [ "${dpu_host_worker_count}" -ge 2 ]; then
    echo -e "Detected ${dpu_host_worker_count} DPU host workers. Deploying cross-node test pod."
    ovn_crossnode_manifest_generated="${PWD}/ovn-test-pods-crossnode-${datetime_string}.yaml"
    cp "${ovn_manifests_dir}/ovn-test-pods-crossnode.yaml" "${ovn_crossnode_manifest_generated}"
    sed -i "s|<OVN_TEST_NAMESPACE>|${SANITY_TESTS_OVN_NAMESPACE}|g" "${ovn_crossnode_manifest_generated}"
    sed -i "s|<OVN_TEST_NODE2>|${dpu_host_workers[1]}|g" "${ovn_crossnode_manifest_generated}"
    sed -i "s|<OVN_TEST_IMAGE>|${SANITY_TESTS_OVN_IMAGE}|g" "${ovn_crossnode_manifest_generated}"
    oc apply -f "${ovn_crossnode_manifest_generated}" --kubeconfig="${mgmt_kubecfg}"
  else
    echo -e "Detected ${dpu_host_worker_count} DPU host worker. Cross-node tests will be skipped."
  fi

  ovn_tests_deployed=true

  echo -e "\nWaiting for OVN test pods to be ready..."
  oc wait --for=condition=Ready pod --all \
    -n "${SANITY_TESTS_OVN_NAMESPACE}" \
    --timeout=120s --kubeconfig="${mgmt_kubecfg}"

  ovn_pod_a_ip=$(oc get pod pod-a -n "${SANITY_TESTS_OVN_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" \
    -o jsonpath='{.status.podIP}')
  ovn_pod_b_ip=$(oc get pod pod-b -n "${SANITY_TESTS_OVN_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" \
    -o jsonpath='{.status.podIP}')
  ovn_svc_ip=$(oc get svc web-svc -n "${SANITY_TESTS_OVN_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" \
    -o jsonpath='{.spec.clusterIP}')
  ovn_svc_host_ip=$(oc get svc web-host-svc -n "${SANITY_TESTS_OVN_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" \
    -o jsonpath='{.spec.clusterIP}')

  ovn_node1_mp0=$(oc get node "${dpu_host_workers[0]}" --kubeconfig="${mgmt_kubecfg}" \
    -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/node-subnets}' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
    | sed 's/\.[0-9]*$/.2/')

  if [ "${dpu_host_worker_count}" -ge 2 ]; then
    ovn_remote_ip=$(oc get pod pod-remote -n "${SANITY_TESTS_OVN_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" \
      -o jsonpath='{.status.podIP}')
    ovn_node2_mp0=$(oc get node "${dpu_host_workers[1]}" --kubeconfig="${mgmt_kubecfg}" \
      -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/node-subnets}' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
      | sed 's/\.[0-9]*$/.2/')
  fi

  echo -e "\nOVN test IPs:"
  echo -e "  pod-a IP: ${ovn_pod_a_ip}"
  echo -e "  pod-b IP: ${ovn_pod_b_ip}"
  echo -e "  web-svc ClusterIP: ${ovn_svc_ip}"
  echo -e "  web-host-svc ClusterIP: ${ovn_svc_host_ip}"
  echo -e "  ${dpu_host_workers[0]} mp0: ${ovn_node1_mp0}"
  [ "${dpu_host_worker_count}" -ge 2 ] && echo -e "  pod-remote IP: ${ovn_remote_ip}"
  [ "${dpu_host_worker_count}" -ge 2 ] && echo -e "  ${dpu_host_workers[1]} mp0: ${ovn_node2_mp0}"

  # Same-node pod-to-pod
  echo -e "\n=== OVN: Same-node pod-to-pod (${dpu_host_workers[0]}) ==="

  ping_mtu_test "OVN: pod-a -> pod-b ping (same node ${dpu_host_workers[0]})" \
    "pod-a" "${SANITY_TESTS_OVN_NAMESPACE}" "${mgmt_kubecfg}" \
    "${SANITY_TESTS_OVN_PING_COUNT}" "normal" "${ovn_pod_b_ip}"

  ping_mtu_test "OVN: pod-b -> pod-a ping (same node ${dpu_host_workers[0]})" \
    "pod-b" "${SANITY_TESTS_OVN_NAMESPACE}" "${mgmt_kubecfg}" \
    "${SANITY_TESTS_OVN_PING_COUNT}" "normal" "${ovn_pod_a_ip}"

  # Cross-node DPU-to-DPU
  echo -e "\n=== OVN: Cross-node DPU-to-DPU ==="
  if [ "${dpu_host_worker_count}" -ge 2 ]; then
    ping_mtu_test "OVN: pod-a (${dpu_host_workers[0]}) -> pod-remote (${dpu_host_workers[1]}) ping" \
      "pod-a" "${SANITY_TESTS_OVN_NAMESPACE}" "${mgmt_kubecfg}" \
      "${SANITY_TESTS_OVN_PING_COUNT}" "normal" "${ovn_remote_ip}"

    ping_mtu_test "OVN: pod-remote (${dpu_host_workers[1]}) -> pod-a (${dpu_host_workers[0]}) ping" \
      "pod-remote" "${SANITY_TESTS_OVN_NAMESPACE}" "${mgmt_kubecfg}" \
      "${SANITY_TESTS_OVN_PING_COUNT}" "normal" "${ovn_pod_a_ip}"
  else
    echo -e "Skipping cross-node tests (only 1 DPU host worker)"
  fi

  # Pod-to-Service
  echo -e "\n=== OVN: Pod-to-Service (ClusterIP: ${ovn_svc_ip}) ==="

  ovn_curl_test "OVN: same-node pod-a -> ClusterIP web-svc" \
    "pod-a" "http://${ovn_svc_ip}:80"

  ovn_curl_test "OVN: same-node pod-a -> service DNS web-svc.${SANITY_TESTS_OVN_NAMESPACE}.svc.cluster.local" \
    "pod-a" "http://web-svc.${SANITY_TESTS_OVN_NAMESPACE}.svc.cluster.local:80"

  ovn_curl_test "OVN: hairpin web-server -> own ClusterIP" \
    "web-server" "http://${ovn_svc_ip}:80"

  ovn_curl_test "OVN: hairpin hostnet web-host -> own ClusterIP" \
    "web-host" "http://${ovn_svc_host_ip}:81"

  # Cross-node service tests
  if [ "${dpu_host_worker_count}" -ge 2 ]; then
    ovn_curl_test "OVN: cross-node pod-remote -> ClusterIP web-svc" \
      "pod-remote" "http://${ovn_svc_ip}:80"

    ovn_curl_test "OVN: cross-node pod-remote -> service DNS web-svc" \
      "pod-remote" "http://web-svc.${SANITY_TESTS_OVN_NAMESPACE}.svc.cluster.local:80"
  else
    echo -e "\nSkipping cross-node service tests (only 1 DPU host worker)"
  fi

  # Control-plane to worker ovn-k8s-mp0
  echo -e "\n=== OVN: Control-plane -> worker ovn-k8s-mp0 ==="

  ping_mtu_test "OVN: pod-cp -> ${dpu_host_workers[0]} mp0 (${ovn_node1_mp0})" \
    "pod-cp" "${SANITY_TESTS_OVN_NAMESPACE}" "${mgmt_kubecfg}" \
    "${SANITY_TESTS_OVN_PING_COUNT}" "normal" "${ovn_node1_mp0}"

  if [ "${dpu_host_worker_count}" -ge 2 ]; then
    ping_mtu_test "OVN: pod-cp -> ${dpu_host_workers[1]} mp0 (${ovn_node2_mp0})" \
      "pod-cp" "${SANITY_TESTS_OVN_NAMESPACE}" "${mgmt_kubecfg}" \
      "${SANITY_TESTS_OVN_PING_COUNT}" "normal" "${ovn_node2_mp0}"
  else
    echo -e "Skipping cp -> second worker mp0 (only 1 DPU host worker)"
  fi

fi

# Output test results summary:
echo -e "\n$test_results_summary"

echo -e "\nTotal of testcases executed: ${total_testcases_executed}"
echo -e "\nNumber of failed tests: ${failed_testcase_count}"

if [ "${failed_testcase_count}" -gt 0 ]; then
  echo "${failed_testcase_count} tests failed !"
  exit 1
else
  echo "All tests passed"
  exit 0
fi
