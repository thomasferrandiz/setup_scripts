#!/usr/bin/env bash
# policyTypes-default tests (MNP-013) and multi-policy union tests
# (MNP-014). Requires 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_topology

log "MNP-013 variant 1: ingress only, policyTypes omitted -> ingress enforced, egress untouched"
apply_static "${POLICIES_DIR}/static/mnp-013-policytypes-ingress-only.yaml"
wait_reconcile mnp-test-a mnp-policytypes-default-ingress-only
assert "client (allowed) -> server TCP 8080" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client-b (not allowed) -> server TCP 8080" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-013-policytypes-ingress-only.yaml"

log "MNP-013 variant 2: egress only, policyTypes omitted -> both egress AND ingress default to enforced"
apply_static "${POLICIES_DIR}/static/mnp-013-policytypes-egress-only.yaml"
wait_reconcile mnp-test-a mnp-policytypes-default-egress-only
assert "client->server TCP 8080 egress (permitted)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client->server TCP 8081 egress (not permitted port)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"
assert "client-b->client TCP 8080 ingress (no ingress section on client => deny all, per CRD default)" deny "$(repeat_check tcp_check mnp-test-a client-b "${CLIENT_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-013-policytypes-egress-only.yaml"

log "MNP-013 variant 3: both ingress and egress present, policyTypes omitted -> both enforced"
apply_static "${POLICIES_DIR}/static/mnp-013-policytypes-both.yaml"
wait_reconcile mnp-test-a mnp-policytypes-default-both
assert "client->server TCP 8080 ingress (permitted)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client-b->server TCP 8080 ingress (not permitted peer)" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
assert "server->client TCP 8081 egress (destination-less rule 'to: podSelector: {}' covers any pod)" allow "$(repeat_check tcp_check mnp-test-a server "${CLIENT_IP_A}" 8081)"
assert "server->client TCP 8080 egress (not the permitted port)" deny "$(repeat_check tcp_check mnp-test-a server "${CLIENT_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-013-policytypes-both.yaml"

log "MNP-013 variant 4: neither ingress nor egress present, policyTypes omitted -> ingress deny-all, egress unaffected"
apply_static "${POLICIES_DIR}/static/mnp-013-policytypes-neither.yaml"
wait_reconcile mnp-test-a mnp-policytypes-default-neither
assert "client->server TCP 8080 (no ingress rules => deny-all)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-013-policytypes-neither.yaml"

log "MNP-014: two ingress policies selecting the same pod union their allow rules"
apply_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"
apply_static "${POLICIES_DIR}/static/mnp-014-ingress-union-a.yaml"
apply_static "${POLICIES_DIR}/static/mnp-014-ingress-union-b.yaml"
wait_reconcile mnp-test-a mnp-union-b
assert "client -> server TCP 8080 (permitted by union-a)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "client-b -> server TCP 8081 (permitted by union-b)" allow "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8081)"
assert "client -> server TCP 8081 (not permitted by either policy)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"
assert "client-b -> server TCP 8080 (not permitted by either policy)" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-014-ingress-union-a.yaml"
delete_static "${POLICIES_DIR}/static/mnp-014-ingress-union-b.yaml"
delete_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"

summary
