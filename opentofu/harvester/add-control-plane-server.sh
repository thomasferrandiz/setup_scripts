#!/bin/bash
# Adds bench-cp-03 as a third control-plane-only server to a running
# dedicated-etcd cluster that has only bench-cp-01..02 (the topology of
# migrate-to-dedicated-etcd.sh before it kept bench-cp-03), without touching
# the worker VMs or the other servers. Rerun after fixing a failure.
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

new_server=bench-cp-03
three_servers='{"bench-cp-01":"control-plane","bench-cp-02":"control-plane","bench-cp-03":"control-plane","bench-etcd-01":"etcd","bench-etcd-02":"etcd","bench-etcd-03":"etcd"}'
two_servers=$(jq -cS --arg name "$new_server" 'del(.[$name])' <<< "$three_servers")
three_servers=$(jq -cS . <<< "$three_servers")

state=$(tofu show -json)
read_worker_count "$state"

if ! last_servers=$(tofu output -json rke2_servers 2>/dev/null); then
  echo "Cannot determine the current server roles: OpenTofu has no rke2_servers output." >&2
  exit 1
fi
last_roles=$(jq -cS .roles <<< "$last_servers")

load_addresses

if [[ "$last_roles" == "$two_servers" ]]; then
  echo "Adding control-plane-only server ${new_server}; ${worker_count} worker VMs and the other servers are left unchanged."
  if [[ "${ASSUME_YES:-}" != yes ]]; then
    read -r -p "Continue? [y/N] " answer
    if [[ ! "$answer" =~ ^[yY]$ ]]; then
      exit 1
    fi
  fi
  # A failed apply may have created the server without recording the new roles.
  wait_for_roles "$two_servers" "$new_server"
  apply_servers "the addition of ${new_server}" ""
  last_roles=$(tofu output -json rke2_servers | jq -cS .roles)
  if [[ "$last_roles" != "$three_servers" ]]; then
    echo "The applied server roles do not include ${new_server}: ${last_roles}. Check the dedicated-etcd topology in main.tf." >&2
    exit 1
  fi
elif [[ "$last_roles" == "$three_servers" ]]; then
  echo "The control plane already has three control-plane servers; checking it."
elif jq -e 'all(.[]; . == "all")' <<< "$last_roles" >/dev/null; then
  echo "The control plane is stacked; convert it with migrate-to-dedicated-etcd.sh, which keeps three control-plane servers." >&2
  exit 1
else
  echo "The last applied server roles are neither two nor three control-plane servers with dedicated etcd: ${last_roles}" >&2
  echo "Finish an interrupted migration with migrate-to-dedicated-etcd.sh first." >&2
  exit 1
fi

push_haproxy
wait_for_roles "$three_servers"
echo "${new_server} is a control-plane server. Existing kubelet and Cilium connections stay on bench-cp-01..02; spread them with kube-burner/rebalance.sh."
