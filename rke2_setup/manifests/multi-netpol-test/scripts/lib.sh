#!/usr/bin/env bash
# Shared helper functions for the MultiNetworkPolicy test scripts.
# Source this file: `source "$(dirname "$0")/lib.sh"`

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICIES_DIR="${ROOT_DIR}/policies"
RESULTS_DIR="${ROOT_DIR}/results"
TOPOLOGY_ENV="${RESULTS_DIR}/topology.env"

mkdir -p "${RESULTS_DIR}"

RECONCILE_WAIT="${RECONCILE_WAIT:-8}"   # fallback fixed sleep when a policy name isn't given to wait_reconcile
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-3}" # seconds for a single connect attempt
CHECK_RETRIES="${CHECK_RETRIES:-3}"     # repeat each flow check this many times

# Controller pod discovery, used by wait_reconcile to confirm enforcement
# actually happened instead of just sleeping a fixed amount of time. See
# comment on wait_reconcile below for why this matters.
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-kube-system}"
CONTROLLER_LABEL_SELECTOR="${CONTROLLER_LABEL_SELECTOR:-name=multi-networkpolicy-nftables}"
CONTROLLER_CONTAINER="${CONTROLLER_CONTAINER:-multi-networkpolicy-nftables}"
RECONCILE_TIMEOUT="${RECONCILE_TIMEOUT:-45}"      # max seconds to wait for confirmed reconciliation
RECONCILE_POLL_INTERVAL="${RECONCILE_POLL_INTERVAL:-3}"
# Extra settle time after a confirmed "reconciled successfully" log line
# before trusting enforcement is live. This was added after observing a real
# gap on an RKE2/macvlan cluster: the controller logs success immediately
# after submitting its nftables netlink transaction, but connections made in
# the following couple of seconds could still see the pre-policy (allow)
# behavior. A short flat sleep plus back-to-back repeat_check attempts
# wasn't enough to catch this: all retries landed inside the same stale
# window and agreed on the wrong answer instead of surfacing as "flaky".
RECONCILE_SETTLE_WAIT="${RECONCILE_SETTLE_WAIT:-8}"
# Delay between repeat_check attempts, so retries are spread over real
# wall-clock time instead of firing back-to-back within the same instant -
# see RECONCILE_SETTLE_WAIT above for why that matters.
REPEAT_CHECK_INTERVAL="${REPEAT_CHECK_INTERVAL:-2}"

PASS_COUNT=0
FAIL_COUNT=0
NA_COUNT=0

for bin in kubectl jq; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: required tool '${bin}' not found in PATH" >&2
    exit 1
  fi
done

log()     { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info()    { printf '    %s\n' "$*"; }
pass_line() { printf '    \033[1;32mPASS\033[0m %s\n' "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_line() { printf '    \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
na_line()   { printf '    \033[1;33mN/A \033[0m %s\n' "$*"; NA_COUNT=$((NA_COUNT + 1)); }

# assert DESCRIPTION EXPECTED_RESULT ACTUAL_RESULT
# EXPECTED_RESULT / ACTUAL_RESULT are "allow" or "deny".
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass_line "${desc} (expected=${expected}, actual=${actual})"
  else
    fail_line "${desc} (expected=${expected}, actual=${actual})"
  fi
}

summary() {
  log "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${NA_COUNT} n/a"
  if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    return 1
  fi
  return 0
}

apply_static() {
  local file="$1"
  info "kubectl apply -f ${file}"
  kubectl apply -f "${file}"
}

apply_invalid_expect_rejection() {
  local file="$1" desc="$2"
  local out rc
  out="$(kubectl apply -f "${file}" 2>&1)"
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    pass_line "${desc}: rejected as expected"
    info "API response: ${out}"
  else
    fail_line "${desc}: was ACCEPTED (expected rejection) - object persisted, remember to clean it up"
    info "API response: ${out}"
  fi
}

delete_static() {
  local file="$1"
  kubectl delete -f "${file}" --ignore-not-found=true >/dev/null
}

# render_policy_template TEMPLATE_FILE OUTPUT_FILE VAR1=val1 [VAR2=val2 ...]
render_policy_template() {
  local template="$1" output="$2"
  shift 2
  cp "${template}" "${output}"
  for pair in "$@"; do
    local key="${pair%%=*}" val="${pair#*=}"
    sed -i.bak "s|__${key}__|${val}|g" "${output}"
    rm -f "${output}.bak"
  done
}

# wait_reconcile [POLICY_NAMESPACE POLICY_NAME]
#
# Without arguments, falls back to a plain fixed sleep (legacy behaviour).
#
# With a namespace/name given, polls every multi-networkpolicy-nftables
# controller pod's logs until each one has logged "MultiNetworkPolicy
# reconciled successfully" for that policy. This guards against a real
# controller race observed in testing: because each DaemonSet pod runs its
# own independent watch/workqueue over the cluster-wide MultiNetworkPolicy
# CRD, one node's controller can silently miss a Create event for a policy
# it is responsible for enforcing (no error, no reconcile log at all for
# that object), leaving the target pod's nftables chains at their
# default-accept state with no drop rule ever installed. A fixed sleep can't
# detect that -- it just makes every subsequent "deny" assertion fail
# looking like an enforcement bug, when only that one node's watch missed
# the event. If confirmation doesn't show up within RECONCILE_TIMEOUT, the
# policy is touched (re-annotated) to force a fresh watch event and is
# re-checked once before giving up and continuing anyway.
wait_reconcile() {
  local ns="${1:-}" name="${2:-}"
  if [[ -z "${ns}" || -z "${name}" ]]; then
    info "waiting ${RECONCILE_WAIT}s for controller reconciliation..."
    sleep "${RECONCILE_WAIT}"
    return
  fi

  if _wait_for_reconcile_confirmation "${ns}" "${name}" "${RECONCILE_TIMEOUT}"; then
    return
  fi

  info "WARNING: no confirmed reconciliation of ${ns}/${name} on one or more controller pods within ${RECONCILE_TIMEOUT}s; forcing a re-sync"
  kubectl annotate "multi-networkpolicies.k8s.cni.cncf.io" -n "${ns}" "${name}" \
    "mnp-test/force-resync=$(date +%s)" --overwrite >/dev/null 2>&1 || true

  if ! _wait_for_reconcile_confirmation "${ns}" "${name}" "${RECONCILE_TIMEOUT}"; then
    info "WARNING: still no confirmation for ${ns}/${name} after forced re-sync; continuing anyway (results below may reflect this)"
  fi
}

# _wait_for_reconcile_confirmation NAMESPACE NAME TIMEOUT
# Returns 0 once every controller pod has logged a successful reconcile for
# NAMESPACE/NAME since this function started polling.
_wait_for_reconcile_confirmation() {
  local ns="$1" name="$2" timeout="$3"
  local start_ts elapsed=0
  start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local pods
  pods="$(kubectl -n "${CONTROLLER_NAMESPACE}" get pods -l "${CONTROLLER_LABEL_SELECTOR}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  if [[ -z "${pods}" ]]; then
    info "could not find controller pods (label ${CONTROLLER_LABEL_SELECTOR} in ${CONTROLLER_NAMESPACE}); falling back to ${RECONCILE_WAIT}s sleep"
    sleep "${RECONCILE_WAIT}"
    return 0
  fi

  info "waiting up to ${timeout}s for '${ns}/${name}' reconciliation on: ${pods}"
  while ((elapsed < timeout)); do
    local all_confirmed=true pod
    for pod in ${pods}; do
      if ! kubectl -n "${CONTROLLER_NAMESPACE}" logs "${pod}" -c "${CONTROLLER_CONTAINER}" \
          --since-time="${start_ts}" 2>/dev/null \
          | grep -q "reconciled successfully.*\"name\": \"${name}\""; then
        all_confirmed=false
        break
      fi
    done
    if [[ "${all_confirmed}" == true ]]; then
      info "confirmed reconciliation of ${ns}/${name} on all controller pods"
      sleep "${RECONCILE_SETTLE_WAIT}" # allow the nftables transaction to fully settle
      return 0
    fi
    sleep "${RECONCILE_POLL_INTERVAL}"
    elapsed=$((elapsed + RECONCILE_POLL_INTERVAL))
  done
  return 1
}

# get_net_ip NAMESPACE POD NET_NAME
# Parses the k8s.v1.cni.cncf.io/networks-status annotation to find the IP
# assigned on the given attachment (matched by NAD name substring).
get_net_ip() {
  local ns="$1" pod="$2" net="$3"
  kubectl get pod -n "${ns}" "${pod}" \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' \
    | jq -r --arg net "${net}" \
      '[.[] | select(.name | endswith($net))][0].ips[0] // empty'
}

# tcp_check FROM_NS FROM_POD DEST_IP PORT
# Returns "allow" or "deny" on stdout based on whether a TCP connection
# succeeds within CONNECT_TIMEOUT seconds.
tcp_check() {
  local from_ns="$1" from_pod="$2" ip="$3" port="$4"
  if kubectl exec -n "${from_ns}" "${from_pod}" -- \
      timeout "${CONNECT_TIMEOUT}" nc -z -w "${CONNECT_TIMEOUT}" "${ip}" "${port}" \
      >/dev/null 2>&1; then
    echo "allow"
  else
    echo "deny"
  fi
}

# udp_check FROM_NS FROM_POD DEST_IP PORT
# Sends a datagram and expects the "ok" echo reply within CONNECT_TIMEOUT
# seconds. Returns "allow" or "deny".
udp_check() {
  local from_ns="$1" from_pod="$2" ip="$3" port="$4"
  local reply
  reply="$(kubectl exec -n "${from_ns}" "${from_pod}" -- \
    timeout "${CONNECT_TIMEOUT}" sh -c "printf ping | nc -u -w ${CONNECT_TIMEOUT} ${ip} ${port}" \
    2>/dev/null | tr -d '[:space:]')"
  if [[ "${reply}" == "ok" ]]; then
    echo "allow"
  else
    echo "deny"
  fi
}

# repeat_check FUNC ARGS...
# Runs the given check function CHECK_RETRIES times and returns "allow"
# only if every attempt agreed. Prints "flaky" if attempts disagreed
# (worth a manual look) otherwise the agreed result.
repeat_check() {
  local func="$1"; shift
  local results=() r
  for ((i = 0; i < CHECK_RETRIES; i++)); do
    r="$("${func}" "$@")"
    results+=("${r}")
    if ((i < CHECK_RETRIES - 1)); then
      sleep "${REPEAT_CHECK_INTERVAL}"
    fi
  done
  local first="${results[0]}"
  for r in "${results[@]}"; do
    if [[ "${r}" != "${first}" ]]; then
      echo "flaky(${results[*]})"
      return
    fi
  done
  echo "${first}"
}

load_topology() {
  if [[ ! -f "${TOPOLOGY_ENV}" ]]; then
    echo "ERROR: ${TOPOLOGY_ENV} not found. Run 10-deploy-topology.sh first." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${TOPOLOGY_ENV}"
}
