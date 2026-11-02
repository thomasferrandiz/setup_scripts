#!/bin/bash
# Converts a running stacked control plane (bench-cp-01..03, each running etcd
# and the control plane) to the dedicated-etcd topology (bench-etcd-01..03 run
# only etcd, bench-cp-01..02 only the control plane) without touching the
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
plan_file="$work/migration.tfplan"

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5
  -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new)
kubectl_command=(sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml)
etcdctl_command=(etcdctl --endpoints=https://127.0.0.1:2379
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key)
rke2_config=/etc/rancher/rke2/config.yaml
ipv4='^[0-9]+(\.[0-9]+){3}$'

# Server roles after each step; step 0 is the stacked control plane and step 7
# the dedicated-etcd topology of main.tf.
steps=(
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"all"}'
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"all","bench-etcd-01":"etcd"}'
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"all","bench-etcd-01":"etcd","bench-etcd-02":"etcd"}'
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"all","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
  '{"bench-cp-01":"all","bench-cp-02":"all","bench-cp-03":"control-plane","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
  '{"bench-cp-01":"all","bench-cp-02":"control-plane","bench-cp-03":"control-plane","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
  '{"bench-cp-01":"control-plane","bench-cp-02":"control-plane","bench-cp-03":"control-plane","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
  '{"bench-cp-01":"control-plane","bench-cp-02":"control-plane","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
)
# The server each step removes from the cluster before applying.
targets=("" "" "" "" bench-cp-03 bench-cp-02 bench-cp-01 bench-cp-03)
descriptions=(""
  "Adding etcd-only server bench-etcd-01"
  "Adding etcd-only server bench-etcd-02"
  "Adding etcd-only server bench-etcd-03"
  "Replacing bench-cp-03 with a control-plane-only server"
  "Replacing bench-cp-02 with a control-plane-only server"
  "Replacing bench-cp-01 with a control-plane-only server; bench-etcd-01 becomes the bootstrap server"
  "Removing bench-cp-03")

load_addresses() {
  virtual_machines=$(tofu output -json virtual_machines)
  if ! jump_ip=$(vm_ip bench-net-01); then
    echo "No valid primary IP found in OpenTofu output for bench-net-01." >&2
    return 1
  fi
}

vm_ip() {
  jq -er --arg name "$1" --arg ipv4 "$ipv4" '
    .[$name].ip_address | select(type == "string" and test($ipv4))
  ' <<< "$virtual_machines"
}

# Runs a command as opensuse on a vm-net-2085 address through the jump host.
# Each hop runs the arguments through a shell, hence the double quoting.
remote_input() {
  local ip=$1 inner outer
  shift
  inner=$(printf '%q ' "$@")
  outer=$(printf '%q ' ssh "${ssh_options[@]}" "opensuse@${ip}" "$inner")
  ssh -i "$jump_host_key" -o IdentitiesOnly=yes "${ssh_options[@]}" -- "opensuse@${jump_ip}" "$outer"
}

remote() {
  remote_input "$@" < /dev/null
}

# Selects a reachable API server other than $2 for kubectl.
choose_admin() {
  local roles=$1 excluded=${2:-} name role ip
  for name in bench-cp-01 bench-cp-02 bench-cp-03; do
    role=$(jq -r --arg name "$name" '.[$name] // ""' <<< "$roles")
    if [[ -z "$role" || "$role" == etcd || "$name" == "$excluded" ]] || ! ip=$(vm_ip "$name"); then
      continue
    fi
    if remote "$ip" "${kubectl_command[@]}" --request-timeout=10s get --raw=/readyz >/dev/null 2>&1; then
      admin_ip=$ip
      return
    fi
  done
  echo "No reachable API server found among the control-plane servers${excluded:+ other than ${excluded}}." >&2
  return 1
}

kctl() {
  remote "$admin_ip" "${kubectl_command[@]}" "$@"
}

# Runs etcdctl in a running etcd static pod, not the one on node $1.
etcd() {
  local excluded=$1 pod
  shift
  pod=$(kctl --request-timeout=30s -n kube-system get pods -l component=etcd -o json | jq -r --arg excluded "etcd-${excluded}" '
    [.items[] | select(.metadata.name != $excluded and .status.phase == "Running") | .metadata.name]
    | sort_by(startswith("etcd-bench-etcd-") | not) | first // empty')
  if [[ -z "$pod" ]]; then
    echo "No running etcd pod found." >&2
    return 1
  fi
  kctl -n kube-system exec "$pod" -- "${etcdctl_command[@]}" "$@"
}

# Prints why the cluster does not match the server roles yet, if it does not.
# Server $2, about to be removed, may or may not still be there.
cluster_problems() {
  local roles=$1 ignored=${2:-} nodes members
  roles=$(jq -c --arg ignored "$ignored" 'del(.[$ignored])' <<< "$roles")
  if ! nodes=$(kctl --request-timeout=30s get nodes -o json); then
    echo "cannot list nodes"
    return
  fi
  jq -r --argjson roles "$roles" --arg ignored "$ignored" '
    [.items[] | (.metadata.labels // {}) as $labels | {
      name: .metadata.name,
      ready: any(.status.conditions[]?; .type == "Ready" and .status == "True"),
      etcd: ($labels["node-role.kubernetes.io/etcd"] == "true"),
      cp: ($labels["node-role.kubernetes.io/control-plane"] == "true")}] as $nodes
    | ($roles | keys[]) as $name
    | ([$nodes[] | select(.name == $name)] | first) as $node
    | if $node == null then "\($name) has not joined"
      elif ($node.ready | not) then "\($name) is not Ready"
      elif $node.etcd != ($roles[$name] != "control-plane") or $node.cp != ($roles[$name] != "etcd")
        then "\($name) does not have the \($roles[$name]) role"
      else empty end,
    ($nodes[] | select((.etcd or .cp) and $roles[.name] == null and .name != $ignored)
      | "\(.name) is still a server")
  ' <<< "$nodes"
  if ! members=$(etcd "" member list -w simple); then
    echo "cannot list etcd members"
    return
  fi
  # Columns: ID, status, name (node name and a random suffix), peer URLs, client URLs, learner.
  jq -rn --argjson roles "$roles" --arg members "$members" --arg ignored "$ignored" '
    [$members | splits("\n") | select(length > 0) | split(", ")] as $rows
    | ($rows[] | select(.[1] != "started" or .[5] == "true") | "etcd member \(.[0]) is \(.[1]), learner \(.[5])"),
    ([$rows[] | .[2] | sub("-[0-9a-f]+$"; "") | select(. != $ignored)] | sort) as $actual
    | ([$roles | to_entries[] | select(.value != "control-plane") | .key] | sort) as $expected
    | if $actual != $expected then "etcd members are \($actual | join(" ")), expected \($expected | join(" "))" else empty end
  '
  if ! etcd "" endpoint health --cluster >/dev/null 2>&1; then
    echo "an etcd endpoint is unhealthy"
  fi
}

# Waits until every server has joined with its role and etcd is healthy.
wait_for_roles() {
  local roles=$1 ignored=${2:-} deadline problems
  deadline=$((SECONDS + 1800))
  echo "Waiting up to 30 minutes for the servers to match: $(jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' <<< "$roles")"
  while (( SECONDS < deadline )); do
    if choose_admin "$roles" "$ignored"; then
      problems=$(cluster_problems "$roles" "$ignored")
      if [[ -z "$problems" ]]; then
        echo "All servers are Ready with their roles, and etcd is healthy."
        return
      fi
      echo "Not ready yet: $(paste -sd ';' - <<< "$problems" | sed 's/;/; /g'); retrying in 20 seconds." >&2
    fi
    sleep 20
  done
  echo "Timed out waiting for the control plane; stopping." >&2
  return 1
}

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

tofu_servers() {
  tofu show -json | jq -c '[.values.root_module.resources[]?
    | select((.type == "harvester_virtualmachine" or .type == "harvester_cloudinit_secret")
        and (.name == "bench_bootstrap" or .name == "bench"))
    | {address, type, name: (.values.name | sub("-cloudinit$"; ""))}]'
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
      any(.[]; .address == $type + ".bench[\"bench-etcd-01\"]")
      and all(.[]; .address != $type + ".bench_bootstrap")' <<< "$servers" >/dev/null; then
      tofu state mv "${type}.bench[\"bench-etcd-01\"]" "${type}.bench_bootstrap"
    fi
  done
}

# Plans a step, refuses any change to the workers or any unexpected deletion, then applies it.
apply_step() {
  local step=$1 target=${targets[$1]} roles=${steps[$1]} args violations roles_hcl line
  # Only the servers and the load balancers' cloud-init are planned: the
  # provider reports drift on every VM (a cloudinitdisk disk block missing
  # from the configuration), which must not be applied to the workers here.
  args=(-input=false -lock-timeout=60s -var="rke2_worker_count=${worker_count}" -var="rke2_control_plane=dedicated-etcd"
    -target=harvester_cloudinit_secret.bench_bootstrap -target=harvester_virtualmachine.bench_bootstrap
    -target=harvester_cloudinit_secret.bench -target=harvester_virtualmachine.bench
    -target=harvester_cloudinit_secret.bench_lb)
  if (( step < 7 )); then
    # Not inside the array assignment: bash 3.2 brace-expands it there despite the quotes.
    roles_hcl=$(jq -r 'to_entries | map("\"\(.key)\"=\"\(.value)\"") | "{" + join(",") + "}"' <<< "$roles")
    args+=(-var="rke2_server_roles=${roles_hcl}")
  fi
  if (( step >= 4 && step <= 6 )) && jq -e --arg target "$target" '
    any(.[]; .type == "harvester_virtualmachine" and .name == $target)' <<< "$(tofu_servers)" >/dev/null; then
    args+=("-replace=harvester_virtualmachine.bench[\"${target}\"]")
  fi
  tofu plan "${args[@]}" -concise -out="$plan_file"
  violations=$(tofu show -json "$plan_file" | jq -r --arg target "$target" '
    def server_name: (.change.before.name // .change.after.name // "") | sub("-cloudinit$"; "");
    .resource_changes[]?
    | select(.mode == "managed" and .change.actions != ["no-op"])
    | "\(.address): \(.change.actions | join("/"))" as $change
    | if .name == "bench_worker" then $change
      elif (.change.actions | index("delete")) != null
        and (((.name == "bench" or .name == "bench_bootstrap") and $target != "" and server_name == $target) | not)
        then $change
      elif .name == "bench" or .name == "bench_bootstrap"
        or (.type == "harvester_cloudinit_secret" and .name == "bench_lb") then empty
      else $change end')
  if [[ -n "$violations" ]]; then
    echo "Refusing to apply step ${step}: the plan has unexpected changes:" >&2
    while IFS= read -r line; do echo "  ${line}"; done <<< "$violations" >&2
    return 1
  fi
  tofu apply -input=false -lock-timeout=60s "$plan_file"
  load_addresses
}

# Cloud-init only configured HAProxy on first boot.
push_haproxy() {
  local config lb ip host
  config=$(tofu output -raw haproxy_config)
  for lb in bench-lb-01 bench-lb-02; do
    if ! ip=$(vm_ip "$lb"); then
      echo "No valid IP found in OpenTofu output for ${lb}; update /etc/haproxy/haproxy.cfg from 'tofu output -raw haproxy_config' by hand." >&2
      return 1
    fi
    # The provider may report the Keepalived VIP, which reaches the active load balancer.
    host=$(remote "$ip" hostname)
    if [[ "${host%%.*}" != "$lb" ]]; then
      echo "${ip}, the address of ${lb}, reaches ${host}; update /etc/haproxy/haproxy.cfg from 'tofu output -raw haproxy_config' by hand." >&2
      return 1
    fi
    # shellcheck disable=SC2016 # Expanded by the remote shell.
    remote_input "$ip" sudo -n sh -ec '
      cat > /etc/haproxy/haproxy.cfg.new
      haproxy -c -q -f /etc/haproxy/haproxy.cfg.new
      if cmp -s /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg; then
        rm /etc/haproxy/haproxy.cfg.new
      else
        mv /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg
        systemctl reload haproxy.service
        echo "HAProxy configuration updated on $(hostname)."
      fi' <<< "$config"
  done
}

# Joined servers keep the RKE2 server address of their first boot, used again
# when RKE2 restarts; bench-cp-01's old address is gone. Control-plane-only
# servers need an etcd server there. bench-etcd-01 becomes a bootstrap server.
point_servers_at_bootstrap() {
  local bootstrap_ip name ip
  bootstrap_ip=$(vm_ip bench-etcd-01)
  remote "$bootstrap_ip" sudo -n sed -i '/^server:/d' "$rke2_config"
  for name in bench-etcd-02 bench-etcd-03 bench-cp-01 bench-cp-02; do
    ip=$(vm_ip "$name")
    remote "$ip" sudo -n sed -i -E "s#^server: .*#server: https://${bootstrap_ip}:9345#" "$rke2_config"
  done
}

state=$(tofu show -json)
worker_names=$(jq -c '[.values.root_module.resources[]?
  | select(.type == "harvester_virtualmachine" and .name == "bench_worker") | .index]' <<< "$state")
worker_count=$(jq '[.[] | ltrimstr("bench-wk-") | tonumber] | max // 0' <<< "$worker_names")
if (( worker_count != $(jq length <<< "$worker_names") )); then
  echo "Some workers below bench-wk-$(printf '%02d' "$worker_count") are missing; finish scaling with scale-workers.sh first." >&2
  exit 1
fi

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
if [[ -z "$current" ]]; then
  echo "The last applied server roles are not a step of this migration: ${last_roles}" >&2
  exit 1
fi

load_addresses

if (( current < 7 )); then
  echo "Migrating the control plane to dedicated etcd nodes; ${worker_count} worker VMs are left unchanged."
  for ((step = current + 1; step <= 7; step++)); do
    echo "  ${step}. ${descriptions[step]}"
  done
  if [[ "${ASSUME_YES:-}" != yes ]]; then
    read -r -p "Continue? [y/N] " answer
    if [[ ! "$answer" =~ ^[yY]$ ]]; then
      exit 1
    fi
  fi
  # A previous run may have removed the next step's server before failing.
  wait_for_roles "${steps[current]}" "${targets[current + 1]}"
  for ((step = current + 1; step <= 7; step++)); do
    echo "Step ${step}/7: ${descriptions[step]}"
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
wait_for_roles "${steps[7]}"
echo "Migration complete: use CONTROL_PLANE=dedicated-etcd (detected automatically by scale-workers.sh)."
