#!/usr/bin/env bash
# Egress enforcement tests: MNP-011 and MNP-012.
# Requires 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_topology

log "Baseline (no egress policy): client egress to server succeeds"
assert "baseline client->server TCP 8080 egress" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

log "MNP-011: egress-only deny-all on app=client"
apply_static "${POLICIES_DIR}/static/mnp-011-egress-deny-all.yaml"
wait_reconcile mnp-test-a mnp-egress-deny-all
assert "deny-all client->server TCP 8080 egress" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "ingress to server is unaffected by an egress-only policy on client" allow "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-011-egress-deny-all.yaml"

log "MNP-012 (podSelector variant): allow egress to app=server on TCP 8080 only"
apply_static "${POLICIES_DIR}/static/mnp-011-egress-deny-all.yaml"
apply_static "${POLICIES_DIR}/static/mnp-012-egress-allow-podselector.yaml"
wait_reconcile mnp-test-a mnp-egress-allow-podselector
assert "client->server TCP 8080 (permitted peer/port)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client->server TCP 8081 (permitted peer, wrong port)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"
delete_static "${POLICIES_DIR}/static/mnp-012-egress-allow-podselector.yaml"

log "MNP-012 (ipBlock + endPort variant): allow egress to server's IP on TCP 8080-8081"
render_policy_template \
  "${POLICIES_DIR}/templates/mnp-012-egress-allow-ipblock.yaml.tmpl" \
  "${RESULTS_DIR}/mnp-012-rendered.yaml" \
  "SERVER_IP_A=${SERVER_IP_A}"
apply_static "${RESULTS_DIR}/mnp-012-rendered.yaml"
wait_reconcile mnp-test-a mnp-egress-allow-ipblock
assert "client->server TCP 8080 (ipBlock, endPort range)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client->server TCP 8081 (ipBlock, endPort range)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"
kubectl delete -f "${RESULTS_DIR}/mnp-012-rendered.yaml" --ignore-not-found=true >/dev/null
delete_static "${POLICIES_DIR}/static/mnp-011-egress-deny-all.yaml"

summary
