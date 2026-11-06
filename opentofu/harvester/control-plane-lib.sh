# shellcheck shell=bash
# Helpers shared by the scripts that change the RKE2 servers of a running
# cluster (migrate-to-dedicated-etcd.sh, add-control-plane-server.sh,
# use-direct-etcd.sh). Sourced from the module directory after the jump host
# key has been checked.
# shellcheck disable=SC2154 # jump_host_key is set by the sourcing script.

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
plan_file="$work/servers.tfplan"
# Addresses that reached each load balancer, as Harvester does not always report them.
lb_cache="$PWD/.lb-addresses"

ssh_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5
  -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new)
kubectl_command=(sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml)
etcdctl_command=(etcdctl --endpoints=https://127.0.0.1:2379
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key)
ipv4='^[0-9]+(\.[0-9]+){3}$'

# Sets worker_count to the number of workers in state; refuses gaps.
read_worker_count() {
  local state=$1 worker_names
  worker_names=$(jq -c '[.values.root_module.resources[]?
    | select(.type == "harvester_virtualmachine" and .name == "bench_worker") | .index]' <<< "$state")
  worker_count=$(jq '[.[] | ltrimstr("bench-wk-") | tonumber] | max // 0' <<< "$worker_names")
  if (( worker_count != $(jq length <<< "$worker_names") )); then
    echo "Some workers below bench-wk-$(printf '%02d' "$worker_count") are missing; finish scaling with scale-workers.sh first." >&2
    return 1
  fi
}

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

tofu_servers() {
  tofu show -json | jq -c '[.values.root_module.resources[]?
    | select((.type == "harvester_virtualmachine" or .type == "harvester_cloudinit_secret")
        and (.name == "bench_bootstrap" or .name == "bench_etcd" or .name == "bench"))
    | {address, type, name: (.values.name | sub("-cloudinit$"; ""))}]'
}

# Plans the servers and the load balancers' cloud-init, refuses any change to
# the workers or any deletion other than of server $2, then applies the plan.
# $1 names the change in errors; further arguments are passed to tofu plan.
apply_servers() {
  local label=$1 deletable=$2 args violations line
  shift 2
  # Only the servers and the load balancers' cloud-init are planned: the
  # provider reports drift on every VM (a cloudinitdisk disk block missing
  # from the configuration), which must not be applied to the workers here.
  args=(-input=false -lock-timeout=60s -var="rke2_worker_count=${worker_count}" -var="rke2_control_plane=dedicated-etcd"
    -target=harvester_cloudinit_secret.bench_bootstrap -target=harvester_virtualmachine.bench_bootstrap
    -target=harvester_cloudinit_secret.bench_etcd -target=harvester_virtualmachine.bench_etcd
    -target=harvester_cloudinit_secret.bench -target=harvester_virtualmachine.bench
    -target=harvester_cloudinit_secret.bench_lb "$@")
  tofu plan "${args[@]}" -concise -out="$plan_file"
  violations=$(tofu show -json "$plan_file" | jq -r --arg target "$deletable" '
    def server_name: (.change.before.name // .change.after.name // "") | sub("-cloudinit$"; "");
    .resource_changes[]?
    | select(.mode == "managed" and .change.actions != ["no-op"])
    | "\(.address): \(.change.actions | join("/"))" as $change
    | if .name == "bench_worker" then $change
      elif (.change.actions | index("delete")) != null
        and (((.name | IN("bench", "bench_etcd", "bench_bootstrap")) and $target != "" and server_name == $target) | not)
        then $change
      elif (.name | IN("bench", "bench_etcd", "bench_bootstrap"))
        or (.type == "harvester_cloudinit_secret" and .name == "bench_lb") then empty
      else $change end')
  if [[ -n "$violations" ]]; then
    echo "Refusing to apply ${label}: the plan has unexpected changes:" >&2
    while IFS= read -r line; do echo "  ${line}"; done <<< "$violations" >&2
    return 1
  fi
  tofu apply -input=false -lock-timeout=60s "$plan_file"
  load_addresses
}

# Prints the candidate addresses of a load balancer: one given in LB_ADDRESSES,
# the last one that reached it, then those Harvester and OpenTofu report.
# OpenTofu state may have none (the load balancers do not wait for a DHCP
# lease) or the Keepalived VIP, and the guest agent does not always report one.
lb_addresses() {
  local lb=$1 entry
  for entry in ${LB_ADDRESSES//,/ }; do
    if [[ "${entry%%=*}" == "$lb" ]]; then
      echo "${entry#*=}"
    fi
  done
  if [[ -r "$lb_cache" ]]; then
    awk -v lb="$lb" '$1 == lb { print $2 }' "$lb_cache"
  fi
  if command -v kubectl >/dev/null && [[ -r local.yaml ]]; then
    kubectl --kubeconfig local.yaml --request-timeout=20s -n default get vmi "$lb" -o json 2>/dev/null \
      | jq -r '.status.interfaces[]? | select(.name == "default") | (.ipAddress, .ipAddresses[]?)
          | strings' || true
  fi
  vm_ip "$lb" || true
}

# Prints an address that reaches load balancer $1, checked with its hostname.
find_lb() {
  local lb=$1 attempt ip host tried
  for ((attempt = 1; attempt <= 6; attempt++)); do
    tried=
    while read -r ip; do
      if [[ ! "$ip" =~ $ipv4 ]]; then
        continue
      fi
      # The VIP reaches the active load balancer, whichever it is.
      if host=$(remote "$ip" hostname 2> "$work/ssh.err") && [[ "${host%%.*}" == "$lb" ]]; then
        { grep -v "^${lb} " "$lb_cache" 2>/dev/null || true; echo "$lb $ip"; } > "$lb_cache.new"
        mv "$lb_cache.new" "$lb_cache"
        echo "$ip"
        return
      fi
      tried+=" ${ip} ($( { echo "${host:+reaches ${host}}"; cat "$work/ssh.err"; } | grep -v '^\*\*' | grep . | tail -n 1))"
    done < <(lb_addresses "$lb" | awk '!seen[$0]++')
    echo "Could not reach ${lb} (tried:${tried:- no address reported}); retrying in 20 seconds." >&2
    sleep 20
  done
  echo "Could not reach ${lb}. Set LB_ADDRESSES=${lb}=<address> and rerun, or update /etc/haproxy/haproxy.cfg from 'tofu output -raw haproxy_config' by hand." >&2
  return 1
}

# Cloud-init only configured HAProxy on first boot.
push_haproxy() {
  local config lb found
  config=$(tofu output -raw haproxy_config)
  for lb in bench-lb-01 bench-lb-02; do
    found=$(find_lb "$lb") || return 1
    # shellcheck disable=SC2016 # Expanded by the remote shell.
    remote_input "$found" sudo -n sh -ec '
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
