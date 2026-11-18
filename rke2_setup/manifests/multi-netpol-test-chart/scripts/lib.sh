#!/usr/bin/env bash
# Shared helper functions for the MultiNetworkPolicy test scripts.
# Source this file: `source "$(dirname "$0")/lib.sh"`

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Topology manifests and MultiNetworkPolicy fixtures are shared with the
# upstream-manifest suite rather than duplicated.
SHARED_DIR="$(cd "${ROOT_DIR}/../multi-netpol-test" && pwd)"
POLICIES_DIR="${SHARED_DIR}/policies"
RESULTS_DIR="${ROOT_DIR}/results"
TOPOLOGY_ENV="${RESULTS_DIR}/topology.env"
CHART_STATE_ENV="${RESULTS_DIR}/chart-install.env"

mkdir -p "${RESULTS_DIR}"

# The chart replaces the cluster's existing rke2-multus release, since its
# cluster-scoped objects (ClusterRoles rke2-multus / rke2-multus-mnp) have
# fixed names and cannot coexist with a second release.
HELM_RELEASE="${HELM_RELEASE:-rke2-multus}"
HELM_NAMESPACE="${HELM_NAMESPACE:-kube-system}"
CHART_VALUES="${CHART_VALUES:-${ROOT_DIR}/values-mnp.yaml}"

# CNI plugin of the test-net-a/test-net-b attachments. A node interface
# cannot hold macvlan and ipvlan sub-interfaces at the same time.
NAD_TYPE="${NAD_TYPE:-macvlan}"
NAD_MASTER="${NAD_MASTER:-eth0}"   # node interface the attachments are created on
if [[ ! "${NAD_TYPE}" =~ ^(macvlan|ipvlan)$ ]]; then
  echo "ERROR: NAD_TYPE must be macvlan or ipvlan (got '${NAD_TYPE}')" >&2
  exit 1
fi
if [[ ! "${NAD_MASTER}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: NAD_MASTER is not a valid interface name: '${NAD_MASTER}'" >&2
  exit 1
fi

RECONCILE_WAIT="${RECONCILE_WAIT:-8}"   # fallback fixed sleep when a policy name isn't given to wait_reconcile
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-3}" # seconds for a single connect attempt
CHECK_RETRIES="${CHECK_RETRIES:-3}"     # repeat each flow check this many times

# Controller pod discovery, used by wait_reconcile to confirm enforcement
# actually happened instead of just sleeping a fixed amount of time. See
# comment on wait_reconcile below for why this matters.
CONTROLLER_NAMESPACE="${HELM_NAMESPACE}"
CONTROLLER_DAEMONSET="${HELM_RELEASE}-mnp"
CONTROLLER_LABEL_SELECTOR="${CONTROLLER_LABEL_SELECTOR:-app=rke2-multus-mnp}"
CONTROLLER_CONTAINER="${CONTROLLER_CONTAINER:-multi-networkpolicy-nftables}"
CUSTOM_RULES_CM="${HELM_RELEASE}-mnp-custom-rules"
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
RECONCILE_SETTLE_WAIT="${RECONCILE_SETTLE_WAIT:-20}"
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
  _force_resync "${ns}" "${name}"
}

# wait_controller_log NAMESPACE NAME MESSAGE SINCE
# Like wait_reconcile, but waits for MESSAGE (a grep regex matched before the
# policy name) logged since SINCE (RFC3339), e.g. for the log line of a
# policy the controller ignores, or for the initial reconciliation by
# controller pods replaced since SINCE.
wait_controller_log() {
  local ns="$1" name="$2" message="$3" since="$4"
  if ! _wait_for_reconcile_confirmation "${ns}" "${name}" "${RECONCILE_TIMEOUT}" "${message}" "${since}"; then
    _force_resync "${ns}" "${name}" "${message}"
  fi
}

_force_resync() {
  local ns="$1" name="$2" message="${3:-reconciled successfully}"

  info "WARNING: no confirmed reconciliation of ${ns}/${name} on one or more controller pods within ${RECONCILE_TIMEOUT}s; forcing a re-sync"
  kubectl annotate "multi-networkpolicies.k8s.cni.cncf.io" -n "${ns}" "${name}" \
    "mnp-test/force-resync=$(date +%s)" --overwrite >/dev/null 2>&1 || true

  if ! _wait_for_reconcile_confirmation "${ns}" "${name}" "${RECONCILE_TIMEOUT}" "${message}"; then
    info "WARNING: still no confirmation for ${ns}/${name} after forced re-sync; continuing anyway (results below may reflect this)"
  fi
}

# _wait_for_reconcile_confirmation NAMESPACE NAME TIMEOUT [MESSAGE [SINCE]]
# Returns 0 once every controller pod has logged MESSAGE (default: a
# successful reconcile) for NAMESPACE/NAME since SINCE (default: when this
# function started polling).
_wait_for_reconcile_confirmation() {
  local ns="$1" name="$2" timeout="$3" message="${4:-reconciled successfully}"
  local start_ts="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" elapsed=0

  local pods
  # Skip pods still terminating after a rollout: they never log the message.
  pods="$(kubectl -n "${CONTROLLER_NAMESPACE}" get pods -l "${CONTROLLER_LABEL_SELECTOR}" -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name] | join(" ")')"
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
          | grep -q "${message}.*\"name\": \"${name}\""; then
        all_confirmed=false
        break
      fi
    done
    if [[ "${all_confirmed}" == true ]]; then
      info "confirmed '${message}' for ${ns}/${name} on all controller pods"
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

# icmp_check FROM_NS FROM_POD DEST_IP
# Returns "allow" if a single ping gets a reply within CONNECT_TIMEOUT
# seconds, "deny" otherwise.
icmp_check() {
  local from_ns="$1" from_pod="$2" ip="$3"
  if kubectl exec -n "${from_ns}" "${from_pod}" -- \
      timeout "$((CONNECT_TIMEOUT + 1))" ping -c 1 -W "${CONNECT_TIMEOUT}" "${ip}" \
      >/dev/null 2>&1; then
    echo "allow"
  else
    echo "deny"
  fi
}

# repeat_check FUNC ARGS...
# Runs the given check function CHECK_RETRIES times and returns "allow"
# only if every attempt agreed. Prints "flaky" if attempts disagreed
# (worth a manual look) otherwise the agreed result.
#
# Before those attempts, fires one throwaway warm-up call for the exact
# same flow and discards its result. A deny check run soon after an
# allowed flow to the same destination (e.g. a deny-all case right after
# the MNP-005 baseline) can intermittently ride a leftover conntrack
# "established" entry through the target pod's `ct state
# established,related accept` rule and come back "allow" even though the
# policy is enforced correctly - confirmed on a live cluster where the
# first probe after applying a deny-all policy returned "allow" and every
# probe after that returned "deny" with no other change. One discarded
# probe consumes that stale state (or a real, correctly-denied attempt if
# there was none) so the counted attempts below start from a clean state.
repeat_check() {
  local func="$1"; shift
  "${func}" "$@" >/dev/null
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

# render_network_attachments OUTPUT_FILE
# Writes the shared macvlan attachments with NAD_TYPE and NAD_MASTER applied.
render_network_attachments() {
  local output="$1"
  local -a substitutions=(-e "s|\"master\": \"eth0\"|\"master\": \"${NAD_MASTER}\"|")
  if [[ "${NAD_TYPE}" == ipvlan ]]; then
    substitutions+=(-e 's|"type": "macvlan"|"type": "ipvlan"|' -e 's|"mode": "bridge"|"mode": "l2"|')
  fi
  sed "${substitutions[@]}" "${SHARED_DIR}/01-network-attachments.yaml" > "${output}"
  # Fail if the shared manifest changed so that a substitution no longer applies.
  local field
  for field in "\"type\": \"${NAD_TYPE}\"" "\"master\": \"${NAD_MASTER}\""; do
    if [[ "$(grep -c -F "${field}" "${output}")" -ne 2 ]]; then
      echo "ERROR: could not set ${field} on both attachments in ${output}" >&2
      return 1
    fi
  done
}

load_topology() {
  if [[ ! -f "${TOPOLOGY_ENV}" ]]; then
    echo "ERROR: ${TOPOLOGY_ENV} not found. Run 10-deploy-topology.sh first." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${TOPOLOGY_ENV}"
}

require_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    echo "ERROR: required tool 'helm' not found in PATH" >&2
    exit 1
  fi
}

# load_chart_state
# Sources results/chart-install.env written by 00-install-chart.sh, which
# records the chart tarball under test (CHART_TGZ), the release revision to
# roll back to on cleanup (PREV_REVISION, empty if the release did not exist)
# and whether the MultiNetworkPolicy CRD was applied by the kit (CRD_APPLIED).
load_chart_state() {
  if [[ ! -f "${CHART_STATE_ENV}" ]]; then
    echo "ERROR: ${CHART_STATE_ENV} not found. Run 00-install-chart.sh first." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${CHART_STATE_ENV}"
}

# helm_upgrade_chart CHART_TGZ [EXTRA_HELM_ARGS...]
# Upgrades (or installs) the release with the chart under test. Values the
# release was previously installed with (e.g. by the RKE2 helm-controller:
# global.systemDefaultRegistry, global.clusterCIDR, ...) are kept, on top of
# the new chart's defaults, then CHART_VALUES and any extra args are applied.
# HELM_EXTRA_ARGS (word-split) is appended to every call, e.g. to override
# the controller image.
helm_upgrade_chart() {
  local chart="$1"; shift
  # shellcheck disable=SC2086
  helm upgrade --install "${HELM_RELEASE}" "${chart}" \
    --namespace "${HELM_NAMESPACE}" \
    --reset-then-reuse-values \
    -f "${CHART_VALUES}" \
    "$@" ${HELM_EXTRA_ARGS:-}
}

# wait_controller_rollout
# Waits for the controller DaemonSet to finish rolling out, including pods
# replaced because a values change altered the pod template.
wait_controller_rollout() {
  kubectl rollout status -n "${CONTROLLER_NAMESPACE}" "daemonset/${CONTROLLER_DAEMONSET}" --timeout=180s
}

# controller_args
# Prints the controller container args of the DaemonSet pod template (JSON array).
controller_args() {
  kubectl get daemonset -n "${CONTROLLER_NAMESPACE}" "${CONTROLLER_DAEMONSET}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="'"${CONTROLLER_CONTAINER}"'")].args}'
}

# mnp_value KEY
# Prints multiNetworkPolicy.KEY as deployed (user values merged with the
# chart defaults), as compact JSON.
mnp_value() {
  helm get values "${HELM_RELEASE}" -n "${HELM_NAMESPACE}" --all -o json \
    | jq -c --arg k "$1" '.multiNetworkPolicy[$k]'
}

# set_mnp_value KEY JSON_VALUE
# Upgrades the release with the chart under test (CHART_TGZ, see
# load_chart_state) and multiNetworkPolicy.KEY=JSON_VALUE, then waits for
# the controller rollout. Values are passed as a JSON file so lists need no
# --set escaping.
set_mnp_value() {
  local key="$1" value="$2" file="${RESULTS_DIR}/mnp-${1}-values.json"
  jq -n --arg k "${key}" --argjson v "${value}" '{multiNetworkPolicy: {($k): $v}}' > "${file}"
  info "helm upgrade with multiNetworkPolicy.${key}=${value}"
  helm_upgrade_chart "${CHART_TGZ}" -f "${file}" >/dev/null && wait_controller_rollout >/dev/null
}
