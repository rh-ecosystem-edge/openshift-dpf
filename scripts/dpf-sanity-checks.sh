#!/bin/bash

# Catch failures in pipelines
 set -o pipefail

# Defining some variables for this test suite
dpf_operator_namespace="dpf-operator-system"

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

## 11-25-25
## Need to add default values for the 3 required variables from .env file in case they are not defined

if [ -z "${SANITY_TESTS_PODS_WORKLOAD_FILE}" ]; then
  SANITY_TESTS_PODS_WORKLOAD_FILE="manifests/post-installation-manual/workload.yaml"
  echo "SANITY_TESTS_PODS_WORKLOAD_FILE env var is not set, after sourcing env.sh file, using default value '${SANITY_TESTS_PODS_WORKLOAD_FILE}' ..."
fi

if [ -z "${SANITY_TESTS_WORKLOAD_NAMESPACE}" ]; then
  SANITY_TESTS_WORKLOAD_NAMESPACE="workload"
  echo "SANITY_TESTS_WORKLOAD_NAMESPACE env var is not set, after sourcing env.sh file, using default value '${SANITY_TESTS_WORKLOAD_NAMESPACE}' ..."
fi

if [ -z "${SANITY_TESTS_PING_COUNT}" ]; then
  SANITY_TESTS_PING_COUNT="20"
  echo "SANITY_TESTS_PING_COUNT env var is not set, after sourcing env.sh file, using default value '${SANITY_TESTS_PING_COUNT}' ...."
fi


echo -e "\nVariables from sourced .env file or default values used in the script:"
echo -e "- KUBECONFIG: '${KUBECONFIG}'"
echo -e "- HOSTED_CLUSTER_NAME: '${HOSTED_CLUSTER_NAME}'"
echo -e "- CLUSTER_NAME: '${CLUSTER_NAME}'"
echo -e "- SANITY_TESTS_PODS_WORKLOAD_FILE: '${SANITY_TESTS_PODS_WORKLOAD_FILE}'"
echo -e "- SANITY_TESTS_WORKLOAD_NAMESPACE: '${SANITY_TESTS_WORKLOAD_NAMESPACE}'"
echo -e "- SANITY_TESTS_PING_COUNT: '${SANITY_TESTS_PING_COUNT}'"

mgmt_kubecfg="${KUBECONFIG}"
echo -e "\n- mgmt_kubecfg: '${mgmt_kubecfg}'"

# Get the hosted cluster kubeconfig
## $ oc get hostedclusters -A --kubeconfig=${mgmt_kubecfg})
## NAMESPACE   NAME   VERSION   KUBECONFIG              PROGRESS    AVAILABLE   PROGRESSING   MESSAGE
## clusters    doca   4.20.0    doca-admin-kubeconfig   Completed   True        False         The hosted control plane is available

## $ oc get hostedclusters -A --no-headers --kubeconfig=${mgmt_kubecfg}) | awk '{print $4}'
## doca-admin-kubeconfig

hosted_namespace=$(oc get hostedclusters -A --no-headers --kubeconfig=${mgmt_kubecfg} | awk '{print $1}')
hosted_kubeconfig_name=$(oc get hostedclusters -A --no-headers --kubeconfig=${mgmt_kubecfg} | awk '{print $4}')
datetime_string=$(date +"%Y-%m-%d_%H-%M-%S")

echo "Currrent working directory: $PWD"

# build path to hosted cluster kubeconfig file
hosted_kubecfg="${PWD}/${HOSTED_CLUSTER_NAME}-kubeconfig-${datetime_string}"
echo -e "\nhosted_kubecfg file path: '${hosted_kubecfg}'"

echo -e "\nExtracting the hosted cluster '${HOSTED_CLUSTER_NAME}' kubeconfig '${hosted_kubeconfig_name}' to a file named '${hosted_kubecfg}'"
oc get secret -n "${hosted_namespace}" "${hosted_kubeconfig_name}" --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.data.kubeconfig}' | base64 -d > "${hosted_kubecfg}"

# check if the hosted cluster kubeconfig file was created successfully
if [ -f "${hosted_kubecfg}" ]; then
  echo -e "\nhosted_kubecfg file was created successfully at path: '${hosted_kubecfg}'"
else
  echo -e "\nFailed to create hosted cluster kubeconfig file '${hosted_kubecfg}'"
  exit 1
fi

echo -e "\nContents of hosted cluster kubeconfig file '${hosted_kubecfg}':"
cat "${hosted_kubecfg}"

echo -e "\nOutput of oc get nodes --kubeconfig='${mgmt_kubecfg}':"
oc get nodes --kubeconfig="${mgmt_kubecfg}"

echo -e "\nOutput of oc get nodes --kubeconfig='${hosted_kubecfg}':"
oc get nodes --kubeconfig="${hosted_kubecfg}"

# Here we need to find number of DPU worker nodes which are ready
# $ oc get dpu -n dpf-operator-system
# NAME                                                    READY   PHASE   AGE
# nvd-srv-27.nvidia.eng.rdu2.dc.redhat.com-mt2437600gzk   True    Ready   2d5h
# nvd-srv-28.nvidia.eng.rdu2.dc.redhat.com-mt2437600utx   True    Ready   27h

get_dpu_output=$(oc get dpu -n ${dpf_operator_namespace} --kubeconfig=${mgmt_kubecfg})
echo -e "Output of oc get dpu:\n${get_dpu_output}"

dpu_worker_list=$(oc get dpu -n ${dpf_operator_namespace} --no-headers --kubeconfig=${mgmt_kubecfg} | awk '$2=="True" && $3=="Ready" {match($1, /\.com/); if (RSTART) print substr($1, 1, RSTART+3)}' | xargs)

echo -e "\nChecking how many DPU worker nodes are in Ready Phase on management cluster"
if [ -z "${dpu_worker_list}" ]; then
  echo "No DPU worker nodes found in Ready Phase on management cluster"
  exit 1
fi  

# delcare empty array
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
      echo "Pass"
      return 0
  else
      echo "Packet loss percent is: ${PACKET_LOSS}, not 0"
      echo "Fail"
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
    echo "Pass"
  else
    echo "Fail"
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
  doca_hbn_worker_pods[$i]=$(oc get pods -n "${dpf_operator_namespace}" --kubeconfig="${hosted_kubecfg}" -o wide | grep "${dpu_workers[$i]}" | grep hbn | awk '{print $1}')
  ## echo -e "doca-hbn pod for worker '${dpu_workers[$i]}' found was: '${doca_hbn_worker_pods[$i]}'"
  # check that doca-hbn pod was found, otherwise exit
  if [ -z "${doca_hbn_worker_pods[$i]}" ]; then
    echo -e "❌ Failed to find doca-hbn pod for DPU worker '${dpu_workers[$i]}'"
    exit 1
  else
    echo -e "✅ Found doca-hbn pod for DPU worker '${dpu_workers[$i]}' is: '${doca_hbn_worker_pods[$i]}'"
  fi  
done

echo -e "\nGetting the doca-hbn container ip address for all the DPU worker nodes"

#declare array doca_hbn_worker_pod_ip[]
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

# oc get pods -n ${SANITY_TESTS_WORKLOAD_NAMESPACE} --kubeconfig=${mgmt_kubecfg} -o wide
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
for i in "${!dpu_workers[@]}"; do

  testcase_title="Test pings from sriov master test pod '${sriov_test_pod_master}' to doca-hbn pod '${doca_hbn_worker_pods[$i]}' on node '${dpu_workers[$i]}'"
  ping_mtu_test "${testcase_title}" "${sriov_test_pod_master}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 1490 "${doca_hbn_worker_pod_ip[$i]}"

  echo -e "\nFinding sriov test worker pod name for dpu_workers array index $i '${dpu_workers[$i]}' to ping doca-hbn pod name '${doca_hbn_worker_pods[$i]}'"
  sriov_test_worker_pods[$i]=$(oc get pods -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o wide | grep "${dpu_workers[$i]}" | awk '{print $1}' | grep -v hostnetwork)
  if [ -z "${sriov_test_worker_pods[$i]}" ]; then
    echo -e "❌ Failed to find sriov test worker pod for DPU worker '${dpu_workers[$i]}'. Exiting script..."
    exit 1
  else
    echo -e "✅ Found sriov test worker pod for DPU worker '${dpu_workers[$i]}': '${sriov_test_worker_pods[$i]}'"

    check_pod_running=$(oc get pods -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o wide | grep "${dpu_workers[$i]}" | awk '{print $3}')
    ## echo "check_pod_running is: ${check_pod_running}"

    # check if the sriov test worker pod is running, if not Running, fail test ...
    if [ "$(oc get pod "${sriov_test_worker_pods[$i]}" -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.status.phase}')" != "Running" ]; then
    ## if [ "${check_pod_running}" != "Running" ]; then
      echo -e "❌ Test pod '${sriov_test_worker_pods[$i]}' is not running, Exiting script..."
      exit 1
    else 
      echo -e "✅ Test pod '${sriov_test_worker_pods[$i]}' is running"
    fi
  fi

  echo -e "\nFinding sriov_test_workers_pods_hostnetwork name for dpu_workers array index $i '${dpu_workers[$i]}' to ping doca-hbn pod name '${doca_hbn_worker_pods[$i]}'"
  sriov_test_worker_pods_hostnetwork[$i]=$(oc get pods -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o wide | grep "${dpu_workers[$i]}" | awk '{print $1}' | grep hostnetwork)
  if [ -z "${sriov_test_worker_pods_hostnetwork[$i]}" ]; then
    echo -e "❌ Failed to find sriov test worker hostnetwork pod for DPU worker '${dpu_workers[$i]}'. Exiting script..."
    exit 1
  else
    echo -e "✅ Found sriov test worker hostnetwork pod for DPU worker '${dpu_workers[$i]}': '${sriov_test_worker_pods_hostnetwork[$i]}'"
    # check if the sriov test worker hostnetwork pod is running, if not Running, fail test ...
    if [ "$(oc get pod "${sriov_test_worker_pods_hostnetwork[$i]}" -n "${SANITY_TESTS_WORKLOAD_NAMESPACE}" --kubeconfig="${mgmt_kubecfg}" -o jsonpath='{.status.phase}')" != "Running" ]; then
      echo -e "❌ Test pod '${sriov_test_worker_pods_hostnetwork[$i]}' is not running, Exiting script..."
      exit 1
    else 
      echo -e "✅ Test pod '${sriov_test_worker_pods_hostnetwork[$i]}' is running"
    fi
  fi

  echo -e "\nList of interfaces that are up on doca-hbn pod '${doca_hbn_worker_pods[$i]}' for DPU worker '${dpu_workers[$i]}':"
  oc exec "${doca_hbn_worker_pods[$i]}" -n "${dpf_operator_namespace}"  --kubeconfig="${hosted_kubecfg}" -c doca-hbn -- ip -4 -o a

  doca_hbn_worker_pod_ip[$i]=$(oc exec "${doca_hbn_worker_pods[$i]}" -n "${dpf_operator_namespace}"  --kubeconfig="${hosted_kubecfg}" -c doca-hbn -- ip a show pf2dpu2_if | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
  echo -e "doca-hbn pod ip address for worker '${dpu_workers[$i]}' is: '${doca_hbn_worker_pod_ip[$i]}'"

  # Test pings from sriov test-worker pod on worker node i:
  testcase_title="Test pings mtu 1490 from sriov worker test pod '${sriov_test_worker_pods[$i]}' to doca-hbn pod ip '${doca_hbn_worker_pod_ip[$i]}' on DPU worker '${dpu_workers[$i]}'"
  ping_mtu_test "$testcase_title" "${sriov_test_worker_pods[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 1490 "${doca_hbn_worker_pod_ip[$i]}"

  # Test pings mtu 1490 from sriov test-worker hostnetwork pod on worker node i:
  testcase_title="Test pings mtu 1490 from sriov worker test pod on hostnetwork '${sriov_test_worker_pods_hostnetwork[$i]}' to doca-hbn pod ip '${doca_hbn_worker_pod_ip[$i]}' on DPU worker '${dpu_workers[$i]}'"
  ping_mtu_test "$testcase_title" "${sriov_test_worker_pods_hostnetwork[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 1490 "${doca_hbn_worker_pod_ip[$i]}"

  # Test pings mtu 8970 from sriov test-worker hostnetwork pod on worker node i:
  testcase_title="Test pings mtu 8970 from sriov worker test pod on hostnetwork '${sriov_test_worker_pods_hostnetwork[$i]}' to doca-hbn pod ip '${doca_hbn_worker_pod_ip[$i]}' on  DPU Worker '${dpu_workers[$i]}'"
  ping_mtu_test "$testcase_title" "${sriov_test_worker_pods_hostnetwork[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" 8970 "${doca_hbn_worker_pod_ip[$i]}"

  #----------  ping google.com on worker node i
  # Test pings from sriov test-worker pod on worker node i to 8.8.8.8 google.com:
  testcase_title="Test pings from sriov worker test pod '${sriov_test_worker_pods[$i]}' to 8.8.8.8 google.com on DPU worker '${dpu_workers[$i]}'"
  ping_mtu_test "$testcase_title" "${sriov_test_worker_pods[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" normal "8.8.8.8"

  # Test pings from sriov test-worker hostnetwork pod on worker node i to 8.8.8.8 google.com:
  testcase_title="Test pings from sriov worker test pod on hostnetwork '${sriov_test_worker_pods_hostnetwork[$i]}' to 8.8.8.8 google.com on DPU worker '${dpu_workers[$i]}'"
  ping_mtu_test "$testcase_title" "${sriov_test_worker_pods_hostnetwork[$i]}" "${SANITY_TESTS_WORKLOAD_NAMESPACE}" "${mgmt_kubecfg}" "${SANITY_TESTS_PING_COUNT}" "normal" "8.8.8.8"

done

echo -e "\nChecking if DPU worker count is 2.  Number of DPU workers in this test suite: ${dpu_worker_count}"

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
