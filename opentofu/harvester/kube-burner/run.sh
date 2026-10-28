#!/bin/bash
set -euo pipefail

workload=${WORKLOAD:-kubelet-density-heavy}
case "$workload" in
  kubelet-density-heavy)
    default_iterations=10 max_iterations=1000 default_hold=10m default_qps=10
    description="PostgreSQL/perfapp pairs"
    ;;
  api-intensive)
    default_iterations=100 max_iterations=5000 default_hold=1m default_qps=50
    description="namespaces with a Deployment, ConfigMap, Secret and Service"
    ;;
  *)
    echo "WORKLOAD must be kubelet-density-heavy or api-intensive." >&2
    exit 1
    ;;
esac
export ITERATIONS=${ITERATIONS:-$default_iterations}
export HOLD_DURATION=${HOLD_DURATION:-$default_hold}
export QPS=${QPS:-$default_qps}
export BURST=${BURST:-$QPS}
export READ_ITERATIONS=${READ_ITERATIONS:-5}
export PATCH_ITERATIONS=${PATCH_ITERATIONS:-3}
export PRE_CREATE_NAMESPACES=${PRE_CREATE_NAMESPACES:-true}
timeout=${TIMEOUT:-2h}
sample_interval=${SAMPLE_INTERVAL:-30}
etcd_mode=${ETCD_METRICS:-auto}
case "$etcd_mode" in
  auto|required|off) ;;
  *)
    echo "ETCD_METRICS must be auto, required or off." >&2
    exit 1
    ;;
esac
kcm_mode=${KCM_METRICS:-auto}
kubelet_mode=${KUBELET_METRICS:-auto}
cilium_mode=${CILIUM_METRICS:-auto}
node_sample_count=${NODE_SAMPLE_COUNT:-5}
for setting in "KCM_METRICS=$kcm_mode" "KUBELET_METRICS=$kubelet_mode" "CILIUM_METRICS=$cilium_mode"; do
  case "${setting#*=}" in
    auto|required|off) ;;
    *)
      echo "${setting%%=*} must be auto, required or off." >&2
      exit 1
      ;;
  esac
done
case "$PRE_CREATE_NAMESPACES" in
  true|false) ;;
  *)
    echo "PRE_CREATE_NAMESPACES must be true or false." >&2
    exit 1
    ;;
esac

positive_integer() {
  if [[ ! "$2" =~ ^[1-9][0-9]{0,4}$ ]] || (( $2 > $3 )); then
    echo "$1 must be an integer between 1 and $3." >&2
    exit 1
  fi
}
duration() {
  if [[ ! "$2" =~ ^[1-9][0-9]{0,3}[smh]$ ]]; then
    echo "$1 must be a positive duration such as 30s, 10m, or 1h." >&2
    exit 1
  fi
}
positive_integer ITERATIONS "$ITERATIONS" "$max_iterations"
positive_integer QPS "$QPS" 1000
positive_integer BURST "$BURST" 1000
positive_integer READ_ITERATIONS "$READ_ITERATIONS" 100
positive_integer PATCH_ITERATIONS "$PATCH_ITERATIONS" 100
positive_integer SAMPLE_INTERVAL "$sample_interval" 9999
positive_integer NODE_SAMPLE_COUNT "$node_sample_count" 100
duration HOLD_DURATION "$HOLD_DURATION"
duration TIMEOUT "$timeout"
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "Set KUBECONFIG to the downstream RKE2 cluster, not Harvester's local.yaml." >&2
  exit 1
fi
for command in kube-burner kubectl jq; do
  if ! command -v "$command" >/dev/null; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

cd "$(dirname "${BASH_SOURCE[0]}")"
results=$(mktemp -d "$PWD/results-$workload-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
context=$(kubectl config current-context 2>/dev/null) || context="(not set)"
# Effective settings, so a results archive can be interpreted on its own.
cat > "$results/parameters.env" <<EOF
STARTED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
CONTEXT=$context
WORKLOAD=$workload
ITERATIONS=$ITERATIONS
QPS=$QPS
BURST=$BURST
HOLD_DURATION=$HOLD_DURATION
READ_ITERATIONS=$READ_ITERATIONS
PATCH_ITERATIONS=$PATCH_ITERATIONS
PRE_CREATE_NAMESPACES=$PRE_CREATE_NAMESPACES
TIMEOUT=$timeout
SAMPLE_INTERVAL=$sample_interval
ETCD_METRICS=$etcd_mode
KCM_METRICS=$kcm_mode
KUBELET_METRICS=$kubelet_mode
CILIUM_METRICS=$cilium_mode
NODE_SAMPLE_COUNT=$node_sample_count
EOF
echo "Context: $context"
echo "Workload $workload: creating $ITERATIONS $description at QPS $QPS; results: $results"
# Check access and metrics availability before creating any workload objects.
kubectl --request-timeout=30s get nodes -o json > "$results/nodes.json"
if ! jq -er '
  [.items[]
    | select((.metadata.labels // {}) | has("node-role.kubernetes.io/control-plane"))
    | {name: .metadata.name, ip: ([.status.addresses[]?
        | select(.type == "InternalIP" and (.address | contains(":") | not))
        | .address] | first)}]
  | if length == 0 then error("No control-plane nodes found")
    elif any(.[]; .ip == null) then error("Control-plane node has no IPv4 InternalIP")
    else sort_by(.name)[] | [.name, ("https://" + .ip + ":6443")] | @tsv
    end
' "$results/nodes.json" > "$results/apiserver-targets.tsv"; then
  echo "Cannot discover API server metrics targets; refusing to run without per-server monitoring." >&2
  exit 1
fi
sample_metrics() {
  if ! kubectl --request-timeout=30s get --raw /apis/metrics.k8s.io/v1beta1/nodes |
    jq -ce 'select(.items | length > 0)'; then
    echo "Node metrics unavailable or empty; refusing to run without monitoring." >&2
    return 1
  fi
}
# Pin each scrape to a node: a load-balanced endpoint would mix unrelated counters.
sample_apiserver_member() {
  local member=$1 endpoint=$2 timestamp samples
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if ! samples=$(kubectl --server="$endpoint" --request-timeout=30s get --raw /metrics |
    awk -v ts="$timestamp" -v member="$member" '
    function label(series, name) {
      if (match(series, "[{,]" name "=\"[^\"]*\"")) {
        return substr(series, RSTART + length(name) + 3, RLENGTH - length(name) - 4)
      }
      return ""
    }
    /^#/ || NF < 2 { next }
    {
      series = substr($0, 1, length($0) - length($NF) - 1)
      name = series
      sub(/\{.*/, "", name)
    }
    name ~ /^(apiserver_current_inflight_requests|apiserver_flowcontrol_current_inqueue_requests|apiserver_flowcontrol_current_executing_requests|apiserver_flowcontrol_rejected_requests_total|process_cpu_seconds_total|process_resident_memory_bytes|go_goroutines)$/ {
      totals[series] += $NF
    }
    name == "apiserver_request_total" {
      totals[name "{verb=\"" label(series, "verb") "\",code=\"" label(series, "code") "\"}"] += $NF
      found = 1
    }
    name ~ /^apiserver_request_duration_seconds_(sum|count)$/ {
      totals[name "{verb=\"" label(series, "verb") "\"}"] += $NF
    }
    # Service creates also allocate a ClusterIP (an IPAddress object), so keep
    # their latency apart. resource comes first so {verb="..." prefixes stay unique.
    name ~ /^apiserver_request_duration_seconds_(sum|count)$/ && label(series, "resource") ~ /^(services|ipaddresses)$/ {
      totals[name "{resource=\"" label(series, "resource") "\",verb=\"" label(series, "verb") "\"}"] += $NF
    }
    # Requests the API server gave up on (timeouts, self-defense).
    name == "apiserver_request_terminations_total" {
      totals[name "{verb=\"" label(series, "verb") "\",resource=\"" label(series, "resource") "\",code=\"" label(series, "code") "\"}"] += $NF
    }
    name ~ /^apiserver_admission_step_admission_duration_seconds_(sum|count)$/ {
      totals[name "{type=\"" label(series, "type") "\",operation=\"" label(series, "operation") "\"}"] += $NF
    }
    name ~ /^apiserver_admission_(controller|webhook)_admission_duration_seconds_(sum|count)$/ {
      totals[name "{name=\"" label(series, "name") "\",operation=\"" label(series, "operation") "\"}"] += $NF
    }
    name ~ /^kube_apiserver_clusterip_allocator_allocation_duration_seconds_(sum|count)$/ {
      totals[name] += $NF
    }
    name ~ /^kube_apiserver_clusterip_allocator_allocation_(errors_)?total$/ {
      totals[name "{scope=\"" label(series, "scope") "\"}"] += $NF
    }
    # The API server as an etcd client: request latency, errors and stored objects.
    name ~ /^etcd_request_(duration_seconds_sum|duration_seconds_count|errors_total)$/ {
      totals[name "{operation=\"" label(series, "operation") "\"}"] += $NF
    }
    name ~ /^(apiserver_storage_objects|apiserver_resource_objects|apiserver_storage_size_bytes)$/ {
      totals[name] += $NF
    }
    END {
      if (!found) exit 1
      for (series in totals) {
        key = series
        if (index(key, "{")) sub(/\{/, "{member=\"" member "\",", key)
        else key = key "{member=\"" member "\"}"
        printf "%s\t%s\t%.17g\n", ts, key, totals[series]
      }
    }' | LC_ALL=C sort); then
    echo "API server metrics unavailable from $member ($endpoint); refusing to run without monitoring." >&2
    return 1
  fi
  printf '%s\n' "$samples"
}
sample_apiserver() {
  local member endpoint
  while IFS=$'\t' read -r member endpoint; do
    sample_apiserver_member "$member" "$endpoint" || return 1
  done < "$results/apiserver-targets.tsv"
}
# etcd's own metrics, read through the API server's pod proxy. RKE2 serves them
# on port 2381 of each server node only with etcd-expose-metrics enabled.
sample_etcd() {
  local timestamp pod samples status=0
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  for pod in $etcd_pods; do
    if ! samples=$(kubectl --request-timeout=30s get --raw \
      "/api/v1/namespaces/kube-system/pods/$pod:2381/proxy/metrics" |
      awk -v ts="$timestamp" -v member="${pod#etcd-}" '
      function label(series, name) {
        if (match(series, "[{,]" name "=\"[^\"]*\"")) {
          return substr(series, RSTART + length(name) + 3, RLENGTH - length(name) - 4)
        }
        return ""
      }
      /^#/ || NF < 2 { next }
      {
        series = substr($0, 1, length($0) - length($NF) - 1)
        name = series
        sub(/\{.*/, "", name)
        key = name "{member=\"" member "\"}"
      }
      name ~ /^(etcd_server_has_leader|etcd_server_is_leader|etcd_server_leader_changes_seen_total|etcd_server_proposals_(committed|applied|failed)_total|etcd_server_proposals_pending|etcd_server_slow_apply_total|etcd_mvcc_db_total_size_in_bytes|etcd_mvcc_db_total_size_in_use_in_bytes|etcd_mvcc_(put|delete|range|txn)_total|etcd_disk_(wal_fsync|backend_commit)_duration_seconds_(sum|count)|etcd_network_peer_round_trip_time_seconds_(sum|count)|process_cpu_seconds_total|process_resident_memory_bytes)$/ {
        totals[key] += $NF
        if (name == "etcd_server_has_leader") found = 1
      }
      # Buckets give fsync/commit percentiles; etcd wants p99 below ~10ms/25ms.
      name ~ /^etcd_disk_(wal_fsync|backend_commit)_duration_seconds_bucket$/ {
        totals[name "{member=\"" member "\",le=\"" label(series, "le") "\"}"] += $NF
      }
      END {
        if (!found) exit 1
        for (series in totals) printf "%s\t%s\t%.17g\n", ts, series, totals[series]
      }' | LC_ALL=C sort); then
      echo "$timestamp: etcd metrics unavailable from $pod" >&2
      status=1
      continue
    fi
    printf '%s\n' "$samples"
  done
  return "$status"
}
# kube-controller-manager's metrics over HTTPS through the pod proxy. RKE2 binds
# port 10257 to 127.0.0.1 and requires authorization for /metrics unless the
# servers set bind-address=0.0.0.0 and add /metrics to authorization-always-allow-paths.
sample_kcm() {
  local timestamp pod samples status=0
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  for pod in $kcm_pods; do
    if ! samples=$(kubectl --request-timeout=30s get --raw \
      "/api/v1/namespaces/kube-system/pods/https:$pod:10257/proxy/metrics" |
      awk -v ts="$timestamp" -v member="${pod#kube-controller-manager-}" '
      function label(series, name) {
        if (match(series, "[{,]" name "=\"[^\"]*\"")) {
          return substr(series, RSTART + length(name) + 3, RLENGTH - length(name) - 4)
        }
        return ""
      }
      /^#/ || NF < 2 { next }
      {
        series = substr($0, 1, length($0) - length($NF) - 1)
        name = series
        sub(/\{.*/, "", name)
        prefix = name "{member=\"" member "\""
      }
      # Time spent waiting for the client-side rate limiter (kube-api-qps/burst).
      name ~ /^rest_client_(rate_limiter_duration|request_duration)_seconds_(sum|count)$/ {
        totals[prefix ",verb=\"" label(series, "verb") "\"}"] += $NF
      }
      name == "rest_client_rate_limiter_duration_seconds_bucket" {
        totals[prefix ",le=\"" label(series, "le") "\"}"] += $NF
      }
      name == "rest_client_requests_total" {
        totals[prefix ",method=\"" label(series, "method") "\",code=\"" label(series, "code") "\"}"] += $NF
        found = 1
      }
      # Controller backlogs, e.g. workqueue_depth{name="deployment"}.
      name ~ /^workqueue_(depth|adds_total|retries_total|queue_duration_seconds_(sum|count))$/ {
        totals[prefix ",name=\"" label(series, "name") "\"}"] += $NF
      }
      name ~ /^(leader_election_master_status|process_cpu_seconds_total|process_resident_memory_bytes)$/ {
        totals[prefix "}"] += $NF
      }
      END {
        if (!found) exit 1
        for (series in totals) printf "%s\t%s\t%.17g\n", ts, series, totals[series]
      }' | LC_ALL=C sort); then
      echo "$timestamp: kube-controller-manager metrics unavailable from $pod" >&2
      status=1
      continue
    fi
    printf '%s\n' "$samples"
  done
  return "$status"
}
# Generic scrape for the node-side components. Each rule is "regex=labels": series
# whose name matches the regex are summed over every label except those listed.
scrape_node_component() {
  local timestamp=$1 path=$2 member=$3 required=$4 rules=$5
  kubectl --request-timeout=30s get --raw "$path" |
    awk -v ts="$timestamp" -v member="$member" -v required="$required" -v rules="$rules" '
    function label(series, name) {
      if (match(series, "[{,]" name "=\"[^\"]*\"")) {
        return substr(series, RSTART + length(name) + 3, RLENGTH - length(name) - 4)
      }
      return ""
    }
    BEGIN {
      count = split(rules, rule, " ")
      for (i = 1; i <= count; i++) {
        split(rule[i], part, "=")
        pattern[i] = "^(" part[1] ")$"
        labels[i] = part[2]
      }
    }
    /^#/ || NF < 2 { next }
    {
      series = substr($0, 1, length($0) - length($NF) - 1)
      name = series
      sub(/\{.*/, "", name)
      for (i = 1; i <= count; i++) {
        if (name !~ pattern[i]) continue
        key = name "{member=\"" member "\""
        kept = split(labels[i], keep, ",")
        for (j = 1; j <= kept; j++) key = key "," keep[j] "=\"" label(series, keep[j]) "\""
        totals[key "}"] += $NF
        if (name == required) found = 1
        break
      }
    }
    END {
      if (!found) exit 1
      for (series in totals) printf "%s\t%s\t%.17g\n", ts, series, totals[series]
    }' | LC_ALL=C sort
}
# The kubelet's metrics through the API server's node proxy: pod sandbox creation
# (the CNI ADD), runtime operations, pod start latency and its own API client.
kubelet_rules="kubelet_run_podsandbox_duration_seconds_(sum|count)= \
kubelet_run_podsandbox_duration_seconds_bucket=le \
kubelet_run_podsandbox_errors_total= \
kubelet_runtime_operations_duration_seconds_(sum|count)=operation_type \
kubelet_runtime_operations_errors_total=operation_type \
kubelet_pod_start_(sli_)?duration_seconds_(sum|count)= \
kubelet_pod_worker_duration_seconds_(sum|count)=operation_type \
kubelet_pleg_relist_duration_seconds_(sum|count)= \
kubelet_running_(pods|containers)= \
rest_client_(rate_limiter_duration|request_duration)_seconds_(sum|count)=verb \
rest_client_requests_total=method,code \
process_cpu_seconds_total= process_resident_memory_bytes="
sample_kubelet() {
  local timestamp node status=0
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  for node in $kubelet_nodes; do
    if ! scrape_node_component "$timestamp" "/api/v1/nodes/$node/proxy/metrics" "$node" \
      kubelet_running_pods "$kubelet_rules"; then
      echo "$timestamp: kubelet metrics unavailable from $node" >&2
      status=1
    fi
  done
  return "$status"
}
# cilium-agent's metrics on port 9962 through the pod proxy; the agent serves them
# only with prometheus.enabled in the rke2-cilium chart values. Endpoint creation
# and regeneration, the agent API rate limiter that paces CNI ADD calls, and its
# Kubernetes client (calls by host, to tell the bootstrap URLs from the Service).
cilium_rules="cilium_endpoint_regeneration_time_stats_seconds_(sum|count)=scope \
cilium_endpoint_regenerations_total=outcome \
cilium_endpoint_state=endpoint_state \
cilium_api_limiter_(processed_requests_total)=api_call,outcome \
cilium_api_limiter_(wait_duration_seconds|processing_duration_seconds|requests_in_flight|rate_limit|adjustment_factor)=api_call,value \
cilium_agent_api_process_time_seconds_(sum|count)=method,path \
cilium_k8s_client_api_calls_total=host,method,return_code \
cilium_k8s_client_(api_latency_time|rate_limiter_duration)_seconds_(sum|count)=method \
cilium_identity=type \
cilium_policy_regeneration_total= \
cilium_errors_warnings_total=level \
process_cpu_seconds_total= process_resident_memory_bytes="
sample_cilium() {
  local timestamp pod node status=0
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  while IFS=$'\t' read -r pod node; do
    [[ -n "$pod" ]] || continue
    if ! scrape_node_component "$timestamp" "/api/v1/namespaces/kube-system/pods/$pod:9962/proxy/metrics" \
      "$node" cilium_endpoint_state "$cilium_rules"; then
      echo "$timestamp: cilium-agent metrics unavailable from $pod on $node" >&2
      status=1
    fi
  done <<< "$cilium_pods"
  return "$status"
}
# Evenly spaced workers in natural name order, so bench-wk-1000 sorts last.
sampled_nodes=$(jq -r --argjson count "$node_sample_count" '
  [.items[]
    | select((.metadata.labels // {}) | has("node-role.kubernetes.io/control-plane") | not)
    | .metadata.name]
  | sort_by([sub("[0-9]+$"; ""), ((capture("(?<n>[0-9]+)$").n // "0") | tonumber)])
  | . as $workers
  | ([$count, length] | min) as $k
  | range(0; $k) | $workers[(. * ($workers | length) / $k | floor)]
' "$results/nodes.json")
if [[ -n "$sampled_nodes" && ( "$kubelet_mode" != off || "$cilium_mode" != off ) ]]; then
  printf '%s\n' "$sampled_nodes" > "$results/sampled-nodes.txt"
fi
kubelet_nodes=
if [[ "$kubelet_mode" != off ]]; then
  kubelet_nodes=$sampled_nodes
  if [[ -z "$kubelet_nodes" ]] || ! sample_kubelet > "$results/kubelet-metrics.tsv" 2>> "$results/kubelet-errors.log"; then
    if [[ "$kubelet_mode" == required ]]; then
      echo "kubelet metrics unavailable (see $results/kubelet-errors.log); the runner reads them through /api/v1/nodes/<node>/proxy/metrics, which needs the nodes/proxy permission. Or set KUBELET_METRICS=off." >&2
      exit 1
    fi
    echo "Warning: kubelet metrics unavailable; pod sandbox latency is not sampled. See KUBELET_METRICS in the README." >&2
    kubelet_nodes=
    rm -f "$results/kubelet-metrics.tsv"
  fi
fi
cilium_pods=
if [[ "$cilium_mode" != off ]]; then
  cilium_pods=$(kubectl --request-timeout=30s -n kube-system get pods -l k8s-app=cilium \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' |
    awk -F'\t' -v nodes="$sampled_nodes" '
      BEGIN { n = split(nodes, list, "\n"); for (i = 1; i <= n; i++) wanted[list[i]] = 1 }
      $2 in wanted')
  if [[ -z "$cilium_pods" ]] || ! sample_cilium > "$results/cilium-metrics.tsv" 2>> "$results/cilium-errors.log"; then
    if [[ "$cilium_mode" == required ]]; then
      echo "cilium-agent metrics unavailable (see $results/cilium-errors.log); set prometheus.enabled: true in the rke2-cilium HelmChartConfig or set CILIUM_METRICS=off." >&2
      exit 1
    fi
    echo "Warning: cilium-agent metrics unavailable; endpoint creation is not sampled. See CILIUM_METRICS in the README." >&2
    cilium_pods=
    rm -f "$results/cilium-metrics.tsv"
  fi
fi
kcm_pods=
if [[ "$kcm_mode" != off ]]; then
  kcm_pods=$(kubectl --request-timeout=30s -n kube-system get pods -l component=kube-controller-manager \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [[ -z "$kcm_pods" ]] || ! sample_kcm > "$results/kcm-metrics.tsv" 2>> "$results/kcm-errors.log"; then
    if [[ "$kcm_mode" == required ]]; then
      echo "kube-controller-manager metrics unavailable (see $results/kcm-errors.log); set kube-controller-manager-arg bind-address=0.0.0.0 and authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics on the RKE2 servers or set KCM_METRICS=off." >&2
      exit 1
    fi
    echo "Warning: kube-controller-manager metrics unavailable; client-side throttling is not sampled. See KCM_METRICS in the README." >&2
    kcm_pods=
    rm -f "$results/kcm-metrics.tsv"
  elif ! grep -q $'\trest_client_rate_limiter_duration_seconds_count' "$results/kcm-metrics.tsv"; then
    echo "Warning: kube-controller-manager exposes no rest_client_rate_limiter_duration_seconds; client-side throttling is not measured." >&2
  fi
fi
etcd_pods=
if [[ "$etcd_mode" != off ]]; then
  etcd_pods=$(kubectl --request-timeout=30s -n kube-system get pods -l component=etcd \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [[ -z "$etcd_pods" ]] || ! sample_etcd > "$results/etcd-metrics.tsv" 2>> "$results/etcd-errors.log"; then
    if [[ "$etcd_mode" == required ]]; then
      echo "etcd metrics unavailable (see $results/etcd-errors.log); enable etcd-expose-metrics on the RKE2 servers or set ETCD_METRICS=off." >&2
      exit 1
    fi
    echo "Warning: etcd server metrics unavailable; only the API server's etcd client metrics are sampled. Enable etcd-expose-metrics on the RKE2 servers." >&2
    etcd_pods=
    rm -f "$results/etcd-metrics.tsv"
  fi
fi
sample_metrics > "$results/metrics-baseline.json"
sample_apiserver > "$results/apiserver-metrics.tsv"
kubectl --request-timeout=30s top nodes > "$results/baseline.txt"

burner_pid=
stop_burner() {
  if [[ -n "$burner_pid" ]]; then
    if kill -0 "$burner_pid" 2>/dev/null; then
      kill -TERM "$burner_pid"
    fi
    if wait "$burner_pid"; then
      :
    else
      echo "kube-burner stopped before normal completion; check $results/kube-burner.log and clean up remaining workload namespaces." >&2
    fi
  fi
}
trap stop_burner EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kube-burner init -c "$workload.yml" --timeout="$timeout" --skip-log-file > "$results/kube-burner.log" 2>&1 &
burner_pid=$!
while kill -0 "$burner_pid" 2>/dev/null; do
  date -u '+%Y-%m-%dT%H:%M:%SZ' >> "$results/node-usage.txt"
  kubectl --request-timeout=30s top nodes >> "$results/node-usage.txt"
  # Keep the original timestamps, CPU quantities and memory working sets.
  sample_metrics >> "$results/node-metrics.jsonl"
  sample_apiserver >> "$results/apiserver-metrics.tsv"
  # etcd samples are supplementary: a failed scrape is logged, not fatal.
  if [[ -n "$etcd_pods" ]]; then
    sample_etcd >> "$results/etcd-metrics.tsv" 2>> "$results/etcd-errors.log" || true
  fi
  if [[ -n "$kcm_pods" ]]; then
    sample_kcm >> "$results/kcm-metrics.tsv" 2>> "$results/kcm-errors.log" || true
  fi
  if [[ -n "$kubelet_nodes" ]]; then
    sample_kubelet >> "$results/kubelet-metrics.tsv" 2>> "$results/kubelet-errors.log" || true
  fi
  if [[ -n "$cilium_pods" ]]; then
    sample_cilium >> "$results/cilium-metrics.tsv" 2>> "$results/cilium-errors.log" || true
  fi
  sleep "$sample_interval"
done
status=0
wait "$burner_pid" || status=$?
burner_pid=
if (( status != 0 )); then
  echo "kube-burner failed ($status). See $results/kube-burner.log; remaining namespaces may need cleanup." >&2
  exit "$status"
fi
kubectl --request-timeout=30s top nodes > "$results/after.txt"
sample_apiserver >> "$results/apiserver-metrics.tsv"
if [[ -n "$etcd_pods" ]]; then
  sample_etcd >> "$results/etcd-metrics.tsv" 2>> "$results/etcd-errors.log" || true
fi
if [[ -n "$kcm_pods" ]]; then
  sample_kcm >> "$results/kcm-metrics.tsv" 2>> "$results/kcm-errors.log" || true
fi
if [[ -n "$kubelet_nodes" ]]; then
  sample_kubelet >> "$results/kubelet-metrics.tsv" 2>> "$results/kubelet-errors.log" || true
fi
if [[ -n "$cilium_pods" ]]; then
  sample_cilium >> "$results/cilium-metrics.tsv" 2>> "$results/cilium-errors.log" || true
fi
for log in etcd-errors.log kcm-errors.log kubelet-errors.log cilium-errors.log; do
  if [[ -f "$results/$log" && ! -s "$results/$log" ]]; then
    rm -f "$results/$log"
  fi
done
# Some kube-burner request failures (e.g. individual patches) are logged without failing the run.
errors=$(grep -c 'level=error' "$results/kube-burner.log" || true)
if (( errors > 0 )); then
  echo "kube-burner completed but logged $errors error(s); see $results/kube-burner.log." >&2
  exit 3
fi
echo "Completed. Node usage: $results/node-usage.txt; API server: $results/apiserver-metrics.tsv"
if [[ -n "$etcd_pods" ]]; then
  echo "etcd: $results/etcd-metrics.tsv"
fi
if [[ -n "$kcm_pods" ]]; then
  echo "kube-controller-manager: $results/kcm-metrics.tsv"
fi
if [[ -n "$kubelet_nodes" ]]; then
  echo "kubelet: $results/kubelet-metrics.tsv"
fi
if [[ -n "$cilium_pods" ]]; then
  echo "cilium-agent: $results/cilium-metrics.tsv"
fi
