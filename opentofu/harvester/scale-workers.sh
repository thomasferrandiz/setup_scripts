#!/bin/bash
set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: [CONTROL_PLANE=stacked|dedicated-etcd] $0 [worker-count=1000]" >&2
  exit 1
fi

target_count=${1:-1000}
if [[ ! "$target_count" =~ ^[1-9][0-9]{0,3}$ ]] || (( target_count > 1000 )); then
  echo "worker-count must be an integer between 1 and 1000." >&2
  exit 1
fi

requested_topology=${CONTROL_PLANE:-}
if [[ -n "$requested_topology" && ! "$requested_topology" =~ ^(stacked|dedicated-etcd)$ ]]; then
  echo "CONTROL_PLANE must be stacked or dedicated-etcd." >&2
  exit 1
fi

for command in tofu jq ssh; do
  if ! command -v "$command" >/dev/null; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

cd "$(dirname "${BASH_SOURCE[0]}")"

jump_host_key="$PWD/jump_host.key"
if [[ ! -r "$jump_host_key" ]]; then
  echo "Jump host private key not found or not readable: ${jump_host_key}" >&2
  exit 1
fi

# Read resources, not outputs: a failed apply may have created only part of a batch.
state=$(tofu show -json)
worker_names=$(jq -c '[
  .values.root_module.resources[]?
  | select(.type == "harvester_virtualmachine" and .name == "bench_worker")
  | .index
] | sort' <<< "$state")
if ! jq -e '
  def worker_name: "bench-wk-" + (if . < 10 then "0" else "" end) + tostring;
  all(.[]; test("^bench-wk-[0-9]+$") and (ltrimstr("bench-wk-") | tonumber | worker_name) == .)
' <<< "$worker_names" >/dev/null; then
  echo "State contains unexpected worker names; expected bench-wk-01, bench-wk-02, ..." >&2
  exit 1
fi
# Gaps below the highest worker come from an interrupted batch; the first apply recreates them.
current_count=$(jq '[.[] | ltrimstr("bench-wk-") | tonumber] | max // 0' <<< "$worker_names")
missing_count=$((current_count - $(jq 'length' <<< "$worker_names")))
if (( missing_count > 0 )); then
  echo "Resuming an interrupted batch: ${missing_count} worker(s) below bench-wk-$(printf '%02d' "$current_count") are missing and will be created."
fi
if (( current_count > target_count )); then
  echo "Refusing to scale down from ${current_count} to ${target_count} workers." >&2
  exit 1
fi

# The topology is read from the server VMs in state: applying the other one
# would replace the control plane. A partial bootstrap is a subset of either.
detected_topology=$(jq -r '
  [.values.root_module.resources[]?
    | select(.type == "harvester_virtualmachine" and (.name == "bench_bootstrap" or .name == "bench"))
    | {bootstrap: (.name == "bench_bootstrap"), name: .values.name}] as $servers
  | ([$servers[] | select(.bootstrap) | .name] | first) as $bootstrap
  | [$servers[].name] as $names
  | if ($servers | length) == 0 then "none"
    elif $bootstrap == "bench-cp-01"
      and ($names - ["bench-cp-01", "bench-cp-02", "bench-cp-03"]) == [] then "stacked"
    elif $bootstrap == "bench-etcd-01"
      and ($names - ["bench-etcd-01", "bench-etcd-02", "bench-etcd-03", "bench-cp-01", "bench-cp-02", "bench-cp-03"]) == []
      then
        # The names match the last migration step too; the applied roles tell them apart.
        {"bench-etcd-01": "etcd", "bench-etcd-02": "etcd", "bench-etcd-03": "etcd", "bench-cp-01": "control-plane",
          "bench-cp-02": "control-plane", "bench-cp-03": "control-plane"} as $dedicated
        | (.values.outputs.rke2_servers.value.roles // null) as $roles
        | if $roles == null or $roles == $dedicated then "dedicated-etcd"
          elif $roles == ($dedicated | del(.["bench-cp-03"])) then "two-control-plane"
          else "unknown" end
    else "unknown"
    end
' <<< "$state")
case "$detected_topology" in
  none)
    topology=${requested_topology:-stacked}
    ;;
  unknown)
    echo "The server VMs in state match no control-plane topology; a control-plane migration may be in progress. Finish it with migrate-to-dedicated-etcd.sh first." >&2
    exit 1
    ;;
  two-control-plane)
    echo "The dedicated-etcd control plane has only bench-cp-01..02. Add bench-cp-03 with add-control-plane-server.sh first." >&2
    exit 1
    ;;
  *)
    if [[ -n "$requested_topology" && "$requested_topology" != "$detected_topology" ]]; then
      echo "CONTROL_PLANE=${requested_topology} does not match the deployed ${detected_topology} control plane. Use migrate-to-dedicated-etcd.sh to convert a stacked cluster." >&2
      exit 1
    fi
    topology=$detected_topology
    ;;
esac
if [[ "$topology" == dedicated-etcd ]]; then
  server_nodes='["bench-etcd-01", "bench-etcd-02", "bench-etcd-03", "bench-cp-01", "bench-cp-02", "bench-cp-03"]'
else
  server_nodes='["bench-cp-01", "bench-cp-02", "bench-cp-03"]'
fi
echo "Control plane: ${topology}."

apply_count() {
  tofu apply -input=false -auto-approve -var="rke2_worker_count=$1" -var="rke2_control_plane=${topology}"
}

wait_for_ready() {
  local count=$1 virtual_machines api_ip jump_ip jump_host nodes deadline
  virtual_machines=$(tofu output -json virtual_machines)
  # bench-cp-01 runs an API server in both topologies.
  if ! api_ip=$(jq -er '
    .["bench-cp-01"].ip_address
    | select(type == "string" and test("^[0-9]+(\\.[0-9]+){3}$"))
  ' <<< "$virtual_machines"); then
    echo "No valid IP found in OpenTofu output for bench-cp-01." >&2
    return 1
  fi
  if ! jump_ip=$(jq -er '
    .["bench-net-01"].ip_address
    | select(type == "string" and test("^[0-9]+(\\.[0-9]+){3}$"))
  ' <<< "$virtual_machines"); then
    echo "No valid primary IP found in OpenTofu output for bench-net-01." >&2
    return 1
  fi
  jump_host="opensuse@${jump_ip}"
  deadline=$((SECONDS + 1800))
  echo "Waiting up to 30 minutes for all $(jq length <<< "$server_nodes") server nodes and ${count} workers to be Ready..."
  while (( SECONDS < deadline )); do
    if nodes=$(ssh -i "$jump_host_key" -o IdentitiesOnly=yes \
      -o BatchMode=yes -o ConnectTimeout=5 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      -o StrictHostKeyChecking=accept-new -- "$jump_host" \
      "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new opensuse@${api_ip} sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml --request-timeout=10s get nodes -o json"); then
      if jq -e --argjson count "$count" --argjson servers "$server_nodes" '
        def worker_name: "bench-wk-" + (if . < 10 then "0" else "" end) + tostring;
        [.items[]
          | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
          | .metadata.name] as $ready
        | ($servers + [range(1; $count + 1) | worker_name]) as $expected
        | ($expected - $ready) == []
      ' <<< "$nodes" >/dev/null; then
        echo "All expected nodes are Ready (${count} workers)."
        return
      fi
      echo "Some expected nodes are not Ready yet; retrying in 15 seconds." >&2
    else
      echo "Could not query node readiness through ${jump_host}; retrying in 15 seconds." >&2
    fi
    sleep 15
  done
  echo "Timed out waiting for Ready nodes; no further workers will be created." >&2
  return 1
}

# Bootstrap a fresh deployment, or reconcile an interrupted batch without deleting it.
apply_count "$current_count"
wait_for_ready "$current_count"

while (( current_count < target_count )); do
  next_count=$(((current_count / 50 + 1) * 50))
  if (( next_count > target_count )); then
    next_count=$target_count
  fi
  echo "Scaling workers from ${current_count} to ${next_count}..."
  apply_count "$next_count"
  wait_for_ready "$next_count"
  current_count=$next_count
done

echo "Scaling complete: ${current_count} workers are Ready."
