#!/usr/bin/env bash
# F24: a standard Kubernetes NetworkPolicy on eth0 alongside a
# MultiNetworkPolicy on test-net-a. The NetworkPolicy only allows
# app=client-b and the MultiNetworkPolicy (MNP-007) only app=client, so each
# interface must follow its own policy only. Requires 10-deploy-topology.sh
# to have run first and a primary CNI that enforces NetworkPolicy.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_topology

NP_FILE="${ROOT_DIR}/policies/np-f24-allow-client-b.yaml"
MNP_FILE="${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"
PRIMARY_IP="$(kubectl get pod -n mnp-test-a server -o jsonpath='{.status.podIP}')"

# check_flows LABEL EXPECTED_ETH0_CLIENT EXPECTED_ETH0_CLIENT_B EXPECTED_NETA_CLIENT EXPECTED_NETA_CLIENT_B
check_flows() {
  local label="$1"
  assert "${label}: eth0 client -> server TCP 8080" "$2" "$(repeat_check tcp_check mnp-test-a client "${PRIMARY_IP}" 8080)"
  assert "${label}: eth0 client-b -> server TCP 8080" "$3" "$(repeat_check tcp_check mnp-test-a client-b "${PRIMARY_IP}" 8080)"
  assert "${label}: test-net-a client -> server TCP 8080" "$4" "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
  assert "${label}: test-net-a client-b -> server TCP 8080" "$5" "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
}

log "F24: baseline, no NetworkPolicy or MultiNetworkPolicy (server primary IP ${PRIMARY_IP})"
check_flows "baseline" allow allow allow allow

log "F24: NetworkPolicy alone (eth0: only app=client-b)"
apply_static "${NP_FILE}"
wait_reconcile
check_flows "NetworkPolicy only" deny allow allow allow

log "F24: NetworkPolicy + MultiNetworkPolicy MNP-007 (test-net-a: only app=client)"
apply_static "${MNP_FILE}"
wait_reconcile mnp-test-a mnp-ingress-allow-client
check_flows "both policies" deny allow allow deny

log "F24: MultiNetworkPolicy alone (NetworkPolicy deleted)"
delete_static "${NP_FILE}"
wait_reconcile
check_flows "MultiNetworkPolicy only" allow allow allow deny

delete_static "${MNP_FILE}"

summary
