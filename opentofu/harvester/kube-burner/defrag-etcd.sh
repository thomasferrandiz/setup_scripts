#!/bin/bash
# Defragment every etcd member, one at a time and the leader last, through the
# RKE2 etcd static pods. A member blocks reads and writes while it defragments,
# so run this before a benchmark, not during one.
set -euo pipefail

timeout=${DEFRAG_TIMEOUT:-120s}

if [[ ! "$timeout" =~ ^[1-9][0-9]*[sm]$ ]]; then
  echo "DEFRAG_TIMEOUT must be a duration in seconds or minutes, for example 120s." >&2
  exit 1
fi
if ! command -v kubectl >/dev/null; then
  echo "Required command not found: kubectl" >&2
  exit 1
fi

# The etcd image has no shell, so etcdctl runs directly.
etcdctl=(etcdctl --endpoints=https://127.0.0.1:2379
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key)

pods=$(kubectl -n kube-system --request-timeout=30s get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | awk '/^etcd-/' | sort)
if [[ -z "$pods" ]]; then
  echo "No etcd pods found in kube-system." >&2
  exit 1
fi

# Member and leader IDs are uint64, so compare them as strings.
order=() leader_pod=""
for pod in $pods; do
  fields=$(kubectl -n kube-system exec "$pod" -- "${etcdctl[@]}" endpoint status -w fields)
  member=$(awk -F' : ' '$1 == "\"MemberID\"" { print $2 }' <<< "$fields")
  leader=$(awk -F' : ' '$1 == "\"Leader\"" { print $2 }' <<< "$fields")
  if [[ -n "$member" && "$member" == "$leader" ]]; then
    leader_pod=$pod
  else
    order+=("$pod")
  fi
done
if [[ -z "$leader_pod" ]]; then
  echo "Could not find the etcd leader." >&2
  exit 1
fi
order+=("$leader_pod")

first=${order[0]}
echo "Before:"
kubectl -n kube-system exec "$first" -- "${etcdctl[@]}" endpoint status --cluster -w table

for pod in "${order[@]}"; do
  if [[ "$pod" == "$leader_pod" ]]; then
    echo "Defragmenting ${pod} (leader)..."
  else
    echo "Defragmenting ${pod}..."
  fi
  if ! kubectl -n kube-system exec "$pod" -- "${etcdctl[@]}" --command-timeout="$timeout" defrag; then
    echo "Defragmentation failed on ${pod}; stopping." >&2
    exit 1
  fi
done

echo "After:"
kubectl -n kube-system exec "$first" -- "${etcdctl[@]}" endpoint status --cluster -w table
