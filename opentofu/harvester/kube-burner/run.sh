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
echo "Context: $(kubectl config current-context)"
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
if [[ -f "$results/etcd-errors.log" && ! -s "$results/etcd-errors.log" ]]; then
  rm -f "$results/etcd-errors.log"
fi
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
