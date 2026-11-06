#!/bin/bash
# Points the API servers of a running dedicated-etcd cluster at the etcd-only
# servers (kube-apiserver etcd-servers) instead of the RKE2 etcd proxy on
# 127.0.0.1:2379, which closes every connection to a member when one 1-second
# supervisor health probe to it times out. Cloud-init sets this on new
# control-plane servers; this script applies OpenTofu, which updates their
# cloud-init, then edits /etc/rancher/rke2/config.yaml and restarts rke2-server
# on one control-plane server at a time. Rerun after fixing a failure.
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

# Prints config $1 with a single etcd-servers=$2 kube-apiserver argument.
with_etcd_servers() {
  awk -v arg="  - \"etcd-servers=$2\"" '
    /^  - "etcd-servers=/ { next }
    { print }
    /^kube-apiserver-arg:/ { print arg; added = 1 }
    END { if (!added) { print "kube-apiserver-arg:"; print arg } }
  ' <<< "$1"
}

# Succeeds once the one kube-apiserver of server $1 runs with etcd-servers=$2 and is ready.
apiserver_uses() {
  local ip=$1 servers=$2 processes
  processes=$(remote "$ip" ps -C kube-apiserver -o args=) || return 1
  [[ $(grep -c . <<< "$processes") == 1 ]] || return 1
  tr ' ' '\n' <<< "$processes" | grep -qxF -- "--etcd-servers=${servers}" || return 1
  remote "$ip" "${kubectl_command[@]}" --request-timeout=10s get --raw=/readyz >/dev/null 2>&1
}

wait_for_apiserver() {
  local name=$1 ip=$2 servers=$3 deadline
  deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    if apiserver_uses "$ip" "$servers"; then
      echo "${name}: kube-apiserver is ready with the direct etcd servers."
      return
    fi
    sleep 10
  done
  echo "Timed out waiting for the kube-apiserver of ${name} to be ready with etcd-servers=${servers}; stopping." >&2
  return 1
}

state=$(tofu show -json)
read_worker_count "$state"

if ! last_servers=$(tofu output -json rke2_servers 2>/dev/null); then
  echo "Cannot determine the current server roles: OpenTofu has no rke2_servers output." >&2
  exit 1
fi
roles=$(jq -cS .roles <<< "$last_servers")
if ! jq -e 'all(.[]; . == "etcd" or . == "control-plane")
    and any(.[]; . == "etcd") and any(.[]; . == "control-plane")' <<< "$roles" >/dev/null; then
  echo "The last applied server roles are not a dedicated-etcd control plane: ${roles}" >&2
  echo "Only control-plane-only servers use etcd-servers; finish migrate-to-dedicated-etcd.sh first." >&2
  exit 1
fi
etcd_names=$(jq -r 'to_entries[] | select(.value == "etcd") | .key' <<< "$roles" | sort)
cp_names=$(jq -r 'to_entries[] | select(.value == "control-plane") | .key' <<< "$roles" | sort)

load_addresses

echo "Pointing the API servers of $(paste -sd ' ' - <<< "$cp_names") at etcd on $(paste -sd ' ' - <<< "$etcd_names"), restarting rke2-server on one at a time; ${worker_count} worker VMs are left unchanged."
if [[ "${ASSUME_YES:-}" != yes ]]; then
  read -r -p "Continue? [y/N] " answer
  if [[ ! "$answer" =~ ^[yY]$ ]]; then
    exit 1
  fi
fi

wait_for_roles "$roles"
# Moves the etcd-only joiners to bench_etcd and renders etcd-servers into the
# control-plane servers' cloud-init; no server is recreated.
apply_servers "the direct etcd servers" ""

servers=
while IFS= read -r name; do
  if ! ip=$(vm_ip "$name"); then
    echo "No valid IP found in OpenTofu output for ${name}." >&2
    exit 1
  fi
  servers+="${servers:+,}https://${ip}:2379"
done <<< "$etcd_names"

# Columns: ID, status, name, peer URLs, client URLs, learner.
members=$(etcd "" member list -w simple | awk -F', ' 'NF >= 5 { print $5 }' | tr ',' '\n' | sort)
if [[ "$members" != "$(tr ',' '\n' <<< "$servers" | sort)" ]]; then
  echo "The etcd client URLs do not match the etcd-only servers in OpenTofu:" >&2
  echo "  etcd:     $(paste -sd ' ' - <<< "$members")" >&2
  echo "  OpenTofu: ${servers//,/ }" >&2
  exit 1
fi

while IFS= read -r name; do
  ip=$(vm_ip "$name")
  config=$(remote "$ip" sudo -n cat "$rke2_config")
  if ! grep -qx 'disable-etcd: *true' <<< "$config"; then
    echo "${name} runs etcd (no disable-etcd: true in ${rke2_config}); stopping." >&2
    exit 1
  fi
  updated=$(with_etcd_servers "$config" "$servers")
  if [[ "$updated" == "$config" ]] && apiserver_uses "$ip" "$servers"; then
    echo "${name}: already uses the direct etcd servers."
    continue
  fi
  if [[ "$updated" != "$config" ]]; then
    # shellcheck disable=SC2016 # $1 expands in the remote shell.
    remote_input "$ip" sudo -n sh -c 'umask 077 && cat > "$1.new" && mv "$1.new" "$1"' sh "$rke2_config" <<< "$updated"
  fi
  echo "${name}: restarting rke2-server."
  remote "$ip" sudo -n systemctl restart rke2-server.service
  wait_for_apiserver "$name" "$ip" "$servers"
  wait_for_roles "$roles"
done <<< "$cp_names"

echo "The API servers connect to etcd directly. Spread the kubelet and Cilium connections that moved during the restarts with kube-burner/rebalance.sh."
