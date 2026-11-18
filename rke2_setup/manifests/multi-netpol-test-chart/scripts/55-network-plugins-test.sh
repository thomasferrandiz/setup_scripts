#!/usr/bin/env bash
# F13: an attachment whose CNI plugin is not in
# multiNetworkPolicy.networkPlugins is ignored by the controller. Removes
# NAD_TYPE from networkPlugins with a helm upgrade, applies an ingress
# deny-all policy (MNP-006) and checks that traffic is still allowed, then
# restores the previous list and checks that the same policy is enforced.
# Requires 00-install-chart.sh and 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_helm
load_topology
load_chart_state

POLICY_FILE="${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"
POLICY_NAME="mnp-ingress-deny-all"

network_plugins_arg() {
  controller_args | jq -r '.[] | select(startswith("--network-plugins=")) | ltrimstr("--network-plugins=")'
}

SAVED_PLUGINS="$(mnp_value networkPlugins)"
if [[ "$(jq --arg t "${NAD_TYPE}" 'index($t) != null' <<<"${SAVED_PLUGINS}")" != true ]]; then
  echo "ERROR: ${NAD_TYPE} is not in multiNetworkPolicy.networkPlugins (${SAVED_PLUGINS}); run 10-deploy-topology.sh first" >&2
  exit 1
fi
# The controller needs at least one plugin, so fall back to one unused by the topology.
REDUCED_PLUGINS="$(jq -c --arg t "${NAD_TYPE}" 'map(select(. != $t)) | if length == 0 then ["bridge"] else . end' <<<"${SAVED_PLUGINS}")"

RESTORED=0
restore_plugins() {
  [[ "${RESTORED}" == 1 ]] && return
  RESTORED=1
  set_mnp_value networkPlugins "${SAVED_PLUGINS}"
}
trap 'restore_plugins; delete_static "${POLICY_FILE}"' EXIT

log "F13: removing ${NAD_TYPE} from multiNetworkPolicy.networkPlugins (${SAVED_PLUGINS} -> ${REDUCED_PLUGINS})"
set_mnp_value networkPlugins "${REDUCED_PLUGINS}"
ARG="$(network_plugins_arg)"
if [[ ",${ARG}," != *",${NAD_TYPE},"* ]]; then
  pass_line "controller started with --network-plugins=${ARG} (no ${NAD_TYPE})"
else
  fail_line "controller still has ${NAD_TYPE} in --network-plugins=${ARG}"
fi

log "F13: applying ingress deny-all on a ${NAD_TYPE} attachment the controller does not handle"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
apply_static "${POLICY_FILE}"
wait_controller_log mnp-test-a "${POLICY_NAME}" "Network type is not supported" "${SINCE}"
assert "unsupported plugin: client -> server TCP 8080 (policy ignored)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "unsupported plugin: client-b -> server TCP 8080 (policy ignored)" allow "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"

log "F13: adding ${NAD_TYPE} back to networkPlugins with the policy in place"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
restore_plugins
ARG="$(network_plugins_arg)"
if [[ ",${ARG}," == *",${NAD_TYPE},"* ]]; then
  pass_line "controller restarted with --network-plugins=${ARG}"
else
  fail_line "controller lacks ${NAD_TYPE} in --network-plugins=${ARG} after the restore"
fi
# The replaced controller pods reconcile the existing policy at startup.
wait_controller_log mnp-test-a "${POLICY_NAME}" "reconciled successfully" "${SINCE}"
assert "supported plugin: client -> server TCP 8080 (policy enforced)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "supported plugin: client-b -> server TCP 8080 (policy enforced)" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"

delete_static "${POLICY_FILE}"

summary
