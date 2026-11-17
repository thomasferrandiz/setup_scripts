#!/usr/bin/env bash
# Ingress enforcement tests: MNP-005 through MNP-010.
# Requires 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_topology

log "MNP-005: baseline - all flows succeed with no MultiNetworkPolicy present"
assert "baseline client->server TCP 8080" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "baseline client->server TCP 8081" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"
assert "baseline client->server UDP 8080" allow "$(repeat_check udp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

log "MNP-006: ingress-only deny-all"
apply_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"
wait_reconcile mnp-test-a mnp-ingress-deny-all
assert "deny-all client->server TCP 8080" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "deny-all client-b->server TCP 8080 (unselected pod, already denied)" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
info "primary-network / test-net-b flows are exercised separately in 40-isolation-tests.sh"

log "MNP-007: allow ingress from app=client on TCP 8080 only"
apply_static "${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"
wait_reconcile mnp-test-a mnp-ingress-allow-client
assert "client (allowed label) -> server TCP 8080" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client-b (different label) -> server TCP 8080" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
assert "client -> server TCP 8081 (not permitted port)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"
assert "client -> server UDP 8080 (not permitted protocol)" deny "$(repeat_check udp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"

log "MNP-008: allow ingress only when namespaceSelector AND podSelector match"
apply_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"
apply_static "${POLICIES_DIR}/static/mnp-008-ingress-allow-ns-and-pod.yaml"
wait_reconcile mnp-test-a mnp-ingress-allow-ns-and-pod
assert "client (mnp-test-a, mnp-test=true) -> server TCP 8080" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client-other-ns (mnp-test-b, mnp-test=false) -> server TCP 8080" deny "$(repeat_check tcp_check mnp-test-b client-other-ns "${SERVER_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-008-ingress-allow-ns-and-pod.yaml"

log "MNP-009: OR'd peers (podSelector OR ipBlock) with an except carve-out"
render_policy_template \
  "${POLICIES_DIR}/templates/mnp-009-ingress-ipblock-except.yaml.tmpl" \
  "${RESULTS_DIR}/mnp-009-rendered.yaml" \
  "TESTNET_A_CIDR=${TESTNET_A_CIDR}" "CLIENT_B_IP=${CLIENT_B_IP_A}"
apply_static "${RESULTS_DIR}/mnp-009-rendered.yaml"
wait_reconcile mnp-test-a mnp-ingress-ipblock-except
assert "client (matches podSelector) -> server TCP 8080" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client-b (in CIDR but excepted) -> server TCP 8080" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
kubectl delete -f "${RESULTS_DIR}/mnp-009-rendered.yaml" --ignore-not-found=true >/dev/null

log "MNP-010: named port, endPort range, and UDP port matching"
apply_static "${POLICIES_DIR}/static/mnp-010-ingress-ports.yaml"
wait_reconcile mnp-test-a mnp-ingress-ports
assert "client -> server TCP 8080 (named port 'http')" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client -> server TCP 8081 (endPort range 8080-8081)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"
assert "client -> server UDP 8080 (UDP port rule)" allow "$(repeat_check udp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client-b -> server TCP 8080 (no matching peer)" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-010-ingress-ports.yaml"
delete_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"

summary
