#!/bin/bash
# Spread long-lived kubelet and Cilium connections across the API servers,
# for example after a control-plane node restarted. goaway-chance alone takes
# hours to move idle agents, and the rke2-agent load balancer never moves them
# back to a server that came back.
set -euo pipefail

cilium=${CILIUM:-yes}
agents=${AGENTS:-yes}
batch_size=${BATCH_SIZE:-50}
ready_timeout=${READY_TIMEOUT:-300}
rollout_timeout=${ROLLOUT_TIMEOUT:-60m}
ssh_user=${SSH_USER:-opensuse}

for setting in "CILIUM=$cilium" "AGENTS=$agents"; do
  if [[ ! "${setting#*=}" =~ ^(yes|no)$ ]]; then
    echo "${setting%%=*} must be yes or no." >&2
    exit 1
  fi
done
if [[ ! "$batch_size" =~ ^[1-9][0-9]{0,3}$ ]] || (( batch_size > 1000 )); then
  echo "BATCH_SIZE must be an integer between 1 and 1000." >&2
  exit 1
fi
if [[ ! "$ready_timeout" =~ ^[1-9][0-9]{0,4}$ ]]; then
  echo "READY_TIMEOUT must be a positive number of seconds." >&2
  exit 1
fi
for command in kubectl jq ssh; do
  if ! command -v "$command" >/dev/null; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

nodes=$(kubectl --request-timeout=30s get nodes -o json)
# name, IPv4 InternalIP and Ready status, control plane first.
node_table=$(jq -r '
  .items[]
  | [.metadata.name,
     ((.metadata.labels // {}) | has("node-role.kubernetes.io/control-plane")),
     ([.status.addresses[]? | select(.type == "InternalIP" and (.address | contains(":") | not)) | .address] | first // "-"),
     any(.status.conditions[]?; .type == "Ready" and .status == "True")]
  | @tsv
' <<< "$nodes" | sort)
servers=$(awk -F'\t' '$2 == "true" && $3 != "-" { print $1 "\thttps://" $3 ":6443" }' <<< "$node_table")
if [[ -z "$servers" ]]; then
  echo "No control-plane node with an IPv4 InternalIP found." >&2
  exit 1
fi

show_goroutines() {
  local name endpoint value
  echo "$1 goroutines per API server:"
  while IFS=$'\t' read -r name endpoint; do
    if value=$(kubectl --server="$endpoint" --request-timeout=30s get --raw /metrics |
      awk '$1 == "go_goroutines" { print $2 }') && [[ -n "$value" ]]; then
      printf '  %s %s\n' "$name" "$value"
    else
      printf '  %s unavailable\n' "$name"
    fi
  done <<< "$servers"
}

show_goroutines "Before:"

if [[ "$cilium" == yes ]]; then
  # With k8s.apiServerURLs, each restarted agent picks a random API server
  # through the kubernetes Service.
  echo "Restarting the Cilium agents..."
  kubectl -n kube-system rollout restart daemonset/cilium
  kubectl -n kube-system rollout status daemonset/cilium --timeout="$rollout_timeout"
fi

if [[ "$agents" == yes ]]; then
  workers=()
  while IFS=$'\t' read -r name control_plane ip ready; do
    if [[ "$control_plane" == true ]]; then
      continue
    elif [[ "$ready" != true || "$ip" == - ]]; then
      echo "Skipping ${name}: not Ready or no IPv4 InternalIP." >&2
    else
      workers+=("${name}"$'\t'"${ip}")
    fi
  done <<< "$node_table"
  echo "Restarting rke2-agent on ${#workers[@]} workers, ${batch_size} at a time..."
  for ((start = 0; start < ${#workers[@]}; start += batch_size)); do
    batch=("${workers[@]:start:batch_size}")
    names=() pids=()
    for worker in "${batch[@]}"; do
      IFS=$'\t' read -r name ip <<< "$worker"
      names+=("$name")
      ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "${ssh_user}@${ip}" sudo -n systemctl restart rke2-agent &
      pids+=("$!")
    done
    failed=false
    for index in "${!pids[@]}"; do
      if ! wait "${pids[index]}"; then
        echo "Failed to restart rke2-agent on ${names[index]}." >&2
        failed=true
      fi
    done
    if [[ "$failed" == true ]]; then
      echo "Stopping before the next batch." >&2
      exit 1
    fi
    kubectl wait --for=condition=Ready --timeout="${ready_timeout}s" "${names[@]/#/node/}"
    echo "  $((start + ${#batch[@]}))/${#workers[@]} workers restarted"
  done
fi

show_goroutines "After:"
