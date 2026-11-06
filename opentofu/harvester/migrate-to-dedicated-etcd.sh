#!/bin/bash
# Converts a running stacked control plane (bench-cp-01..03, each running etcd
# and the control plane) to the dedicated-etcd topology (bench-etcd-01..03 run
# only etcd, bench-cp-01..03 only the control plane) without touching the
# worker VMs. Servers change one at a time, so etcd keeps quorum and at least
# two API servers stay up. Rerun after fixing a failure: it resumes from the
# server roles of the last successful apply.
set -euo pipefail

if (( $# > 0 )); then
  echo "Usage: [ASSUME_YES=yes] $0" >&2
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

# shellcheck source=control-plane-lib.sh
source ./control-plane-lib.sh

rke2_config=/etc/rancher/rke2/config.yaml

# Server roles after each step; step 0 is the stacked control plane and step 6
# the dedicated-etcd topology of main.tf.
steps=(
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"all"}'
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"all","bench-etcd-01":"etcd"}'
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"all","bench-etcd-01":"etcd","bench-etcd-02":"etcd"}'
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"all","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"control-plane","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
  '{"bench-cp-01":"all","bench-cp-02":"control-plane","bench-cp-03":"control-plane","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
  '{"bench-cp-01":"control-plane","bench-cp-02":"control-plane","bench-cp-03":"control-plane","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
)
final=$((${#steps[@]} - 1))
# The server each step removes from the cluster before applying.
targets=("" "" "" "" bench-cp-03 bench-cp-02 bench-cp-01)
descriptions=(""
  "Adding etcd-only server bench-etcd-01"
  "Adding etcd-only server bench-etcd-02"
  "Adding etcd-only server bench-etcd-03"
  "Replacing bench-cp-03 with a control-plane-only server"
  "Replacing bench-cp-02 with a control-plane-only server"
  "Replacing bench-cp-01 with a control-plane-only server; bench-etcd-01 becomes the bootstrap server")

# Drains a server, stops RKE2 on it and deletes its node, which removes its etcd member.
remove_server() {
  local name=$1 roles=$2 ip ready member attempt
  choose_admin "$roles" "$name"
  ready=$(kctl --request-timeout=30s get nodes -o json | jq -r --arg name "$name" '
    [.items[] | select(.metadata.name == $name)
      | any(.status.conditions[]?; .type == "Ready" and .status == "True")]
    | if length == 0 then "absent" else first end')
  if [[ "$ready" != absent ]]; then
    echo "Draining ${name}..."
    kctl drain "$name" --ignore-daemonsets --delete-emptydir-data --force --timeout=10m
    echo "Stopping RKE2 on ${name}..."
    # Stopping the service leaves the static pods running; rke2-killall.sh stops them.
    # shellcheck disable=SC2016 # Expanded by the remote shell.
    if ! ip=$(vm_ip "$name") || ! remote "$ip" sudo -n sh -c '
      systemctl disable --now rke2-server.service
      for script in /usr/local/bin/rke2-killall.sh /usr/bin/rke2-killall.sh /opt/rke2/bin/rke2-killall.sh; do
        if [ -x "$script" ]; then exec "$script" >/dev/null; fi
      done
      echo "rke2-killall.sh not found" >&2
      exit 1'; then
      if [[ "$ready" == true ]]; then
        echo "Could not stop RKE2 on ${name} while it is Ready; stopping." >&2
        return 1
      fi
      echo "Could not reach ${name}, which is not Ready; continuing." >&2
    fi
    echo "Deleting node ${name}..."
    kctl delete node "$name" --timeout=5m
  fi
  # RKE2 removes the etcd member of a deleted node; remove it directly if it does not.
  for ((attempt = 1; ; attempt++)); do
    member=$(etcd "$name" member list -w simple | awk -F', ' -v prefix="${name}-" 'index($3, prefix) == 1 { print $1 }')
    if [[ -z "$member" ]]; then
      return
    elif (( attempt > 24 )); then
      echo "Removing etcd member ${member} of ${name}..."
      etcd "$name" member remove "$member"
      return
    fi
    sleep 5
  done
}

# bench-etcd-01 replaces bench-cp-01 as the bootstrap server, without recreating either.
swap_bootstrap() {
  local servers type
  servers=$(tofu_servers)
  for type in harvester_virtualmachine harvester_cloudinit_secret; do
    if jq -e --arg address "${type}.bench_bootstrap" 'any(.[]; .address == $address and .name == "bench-cp-01")' <<< "$servers" >/dev/null; then
      tofu state mv "${type}.bench_bootstrap" "${type}.bench[\"bench-cp-01\"]"
    fi
  done
  servers=$(tofu_servers)
  for type in harvester_virtualmachine harvester_cloudinit_secret; do
    if jq -e --arg type "$type" '
      any(.[]; .address == $type + ".bench_etcd[\"bench-etcd-01\"]")
      and all(.[]; .address != $type + ".bench_bootstrap")' <<< "$servers" >/dev/null; then
      tofu state mv "${type}.bench_etcd[\"bench-etcd-01\"]" "${type}.bench_bootstrap"
    fi
  done
}

# Applies the server roles of a step; its target server may be deleted and recreated.
apply_step() {
  local step=$1 target=${targets[$1]} roles_hcl args=()
  # Not inside the array assignment: bash 3.2 brace-expands it there despite the quotes.
  roles_hcl=$(jq -r 'to_entries | map("\"\(.key)\"=\"\(.value)\"") | "{" + join(",") + "}"' <<< "${steps[step]}")
  args+=(-var="rke2_server_roles=${roles_hcl}")
  if [[ -n "$target" ]] && jq -e --arg target "$target" '
    any(.[]; .type == "harvester_virtualmachine" and .name == $target)' <<< "$(tofu_servers)" >/dev/null; then
    args+=("-replace=harvester_virtualmachine.bench[\"${target}\"]")
  fi
  apply_servers "step ${step}" "$target" "${args[@]}"
}

# Joined servers keep the RKE2 server address of their first boot, used again
# when RKE2 restarts; bench-cp-01's old address is gone. Control-plane-only
# servers need an etcd server there. bench-etcd-01 becomes a bootstrap server.
point_servers_at_bootstrap() {
  local bootstrap_ip name ip
  bootstrap_ip=$(vm_ip bench-etcd-01)
  remote "$bootstrap_ip" sudo -n sed -i '/^server:/d' "$rke2_config"
  for name in bench-etcd-02 bench-etcd-03 bench-cp-01 bench-cp-02 bench-cp-03; do
    ip=$(vm_ip "$name")
    remote "$ip" sudo -n sed -i -E "s#^server: .*#server: https://${bootstrap_ip}:9345#" "$rke2_config"
  done
}

state=$(tofu show -json)
read_worker_count "$state"

if last_servers=$(tofu output -json rke2_servers 2>/dev/null); then
  last_roles=$(jq -cS .roles <<< "$last_servers")
elif jq -e '[.values.root_module.resources[]?
    | select(.type == "harvester_virtualmachine" and (.name == "bench_bootstrap" or .name == "bench"))
    | .values.name] | sort == ["bench-cp-01", "bench-cp-02", "bench-cp-03"]' <<< "$state" >/dev/null; then
  # State from before the topology option: the stacked control plane.
  last_roles=$(jq -cS . <<< "${steps[0]}")
else
  echo "Cannot determine the current server roles from OpenTofu state." >&2
  exit 1
fi
current=
for step in "${!steps[@]}"; do
  if [[ "$(jq -cS . <<< "${steps[step]}")" == "$last_roles" ]]; then
    current=$step
  fi
done
if [[ -z "$current" && "$last_roles" == "$(jq -cS 'del(.["bench-cp-03"])' <<< "${steps[final]}")" ]]; then
  echo "The control plane uses dedicated etcd nodes with only two control-plane servers; add bench-cp-03 with add-control-plane-server.sh." >&2
  exit 1
elif [[ -z "$current" ]]; then
  echo "The last applied server roles are not a step of this migration: ${last_roles}" >&2
  exit 1
fi

load_addresses

if (( current < final )); then
  echo "Migrating the control plane to dedicated etcd nodes; ${worker_count} worker VMs are left unchanged."
  for ((step = current + 1; step <= final; step++)); do
    echo "  ${step}. ${descriptions[step]}"
  done
  if [[ "${ASSUME_YES:-}" != yes ]]; then
    read -r -p "Continue? [y/N] " answer
    if [[ ! "$answer" =~ ^[yY]$ ]]; then
      exit 1
    fi
  fi
  # A previous run may have stopped after an apply, before updating HAProxy.
  if (( current > 0 )); then
    push_haproxy
  fi
  # A previous run may have removed the next step's server before failing.
  wait_for_roles "${steps[current]}" "${targets[current + 1]}"
  for ((step = current + 1; step <= final; step++)); do
    echo "Step ${step}/${final}: ${descriptions[step]}"
    if [[ -n "${targets[step]}" ]]; then
      remove_server "${targets[step]}" "${steps[step - 1]}"
    fi
    if (( step == 6 )); then
      swap_bootstrap
    fi
    apply_step "$step"
    push_haproxy
    wait_for_roles "${steps[step]}"
  done
else
  echo "The control plane already uses dedicated etcd nodes; checking it."
fi

point_servers_at_bootstrap
push_haproxy
wait_for_roles "${steps[final]}"
echo "Migration complete: use CONTROL_PLANE=dedicated-etcd (detected automatically by scale-workers.sh)."
