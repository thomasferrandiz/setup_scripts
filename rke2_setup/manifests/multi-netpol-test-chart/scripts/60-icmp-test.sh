#!/usr/bin/env bash
# F15: ICMP under default-deny. With multiNetworkPolicy.acceptICMP=true the
# controller accepts ICMP in its common chains, so ping to a pod selected by
# an ingress deny-all policy (MNP-006) succeeds while TCP is denied; with
# acceptICMP=false ping is denied too. Restores the previous value at the end.
# Requires 00-install-chart.sh and 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_helm
load_topology
load_chart_state

POLICY_FILE="${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"
POLICY_NAME="mnp-ingress-deny-all"

has_accept_icmp_arg() {
  controller_args | jq -e 'index("--accept-icmp") != null' >/dev/null
}

SAVED_ACCEPT_ICMP="$(mnp_value acceptICMP)"
if [[ "${SAVED_ACCEPT_ICMP}" != true && "${SAVED_ACCEPT_ICMP}" != false ]]; then
  na_line "F15: chart has no multiNetworkPolicy.acceptICMP value (got ${SAVED_ACCEPT_ICMP})"
  summary
  exit
fi
RESTORED=0
restore_accept_icmp() {
  [[ "${RESTORED}" == 1 ]] && return
  RESTORED=1
  set_mnp_value acceptICMP "${SAVED_ACCEPT_ICMP}"
}
trap 'delete_static "${POLICY_FILE}"; restore_accept_icmp' EXIT

log "F15: baseline, no MultiNetworkPolicy"
assert "baseline: client -> server ping on test-net-a" allow "$(repeat_check icmp_check mnp-test-a client "${SERVER_IP_A}")"

log "F15: acceptICMP=true under ingress deny-all"
set_mnp_value acceptICMP true
if has_accept_icmp_arg; then
  pass_line "controller started with --accept-icmp"
else
  fail_line "controller lacks --accept-icmp with acceptICMP=true"
fi
apply_static "${POLICY_FILE}"
wait_reconcile mnp-test-a "${POLICY_NAME}"
assert "acceptICMP=true: client -> server ping (ICMP accepted)" allow "$(repeat_check icmp_check mnp-test-a client "${SERVER_IP_A}")"
assert "acceptICMP=true: client -> server TCP 8080 (deny-all enforced)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

log "F15: acceptICMP=false under ingress deny-all"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set_mnp_value acceptICMP false
if ! has_accept_icmp_arg; then
  pass_line "controller started without --accept-icmp"
else
  fail_line "controller still has --accept-icmp with acceptICMP=false"
fi
# The replaced controller pods rebuild the common chains when they reconcile
# the existing policy at startup.
wait_controller_log mnp-test-a "${POLICY_NAME}" "reconciled successfully" "${SINCE}"
assert "acceptICMP=false: client -> server ping (denied)" deny "$(repeat_check icmp_check mnp-test-a client "${SERVER_IP_A}")"
assert "acceptICMP=false: client -> server TCP 8080 (deny-all enforced)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

log "F15: restoring acceptICMP=${SAVED_ACCEPT_ICMP} and removing the policy"
delete_static "${POLICY_FILE}"
restore_accept_icmp
wait_reconcile
assert "policy removed: client -> server ping" allow "$(repeat_check icmp_check mnp-test-a client "${SERVER_IP_A}")"

summary
