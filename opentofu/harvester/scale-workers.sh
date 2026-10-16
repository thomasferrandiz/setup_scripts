#!/bin/bash
set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: $0 [worker-count=500]" >&2
  exit 1
fi

target_count=${1:-500}
if [[ ! "$target_count" =~ ^[1-9][0-9]{0,2}$ ]] || (( target_count > 500 )); then
  echo "worker-count must be an integer between 1 and 500." >&2
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
worker_names=$(tofu show -json | jq -c '[
  .values.root_module.resources[]?
  | select(.type == "harvester_virtualmachine" and .name == "bench_worker")
  | .index
] | sort')
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

apply_count() {
  tofu apply -input=false -auto-approve -var="rke2_worker_count=$1"
}

wait_for_ready() {
  local count=$1 virtual_machines bootstrap_ip jump_ip jump_host nodes deadline
  virtual_machines=$(tofu output -json virtual_machines)
  if ! bootstrap_ip=$(jq -er '
    .["bench-cp-01"].ip_address
    | select(type == "string" and test("^[0-9]+(\\.[0-9]+){3}$"))
  ' <<< "$virtual_machines"); then
    echo "No valid bootstrap IP found in OpenTofu output for bench-cp-01." >&2
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
  echo "Waiting up to 30 minutes for all 3 control-plane nodes and ${count} workers to be Ready..."
  while (( SECONDS < deadline )); do
    if nodes=$(ssh -i "$jump_host_key" -o IdentitiesOnly=yes \
      -o BatchMode=yes -o ConnectTimeout=5 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      -o StrictHostKeyChecking=accept-new -- "$jump_host" \
      "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new opensuse@${bootstrap_ip} sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml --request-timeout=10s get nodes -o json"); then
      if jq -e --argjson count "$count" '
        def worker_name: "bench-wk-" + (if . < 10 then "0" else "" end) + tostring;
        [.items[]
          | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
          | .metadata.name] as $ready
        | ["bench-cp-01", "bench-cp-02", "bench-cp-03",
           (range(1; $count + 1) | worker_name)] as $expected
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
