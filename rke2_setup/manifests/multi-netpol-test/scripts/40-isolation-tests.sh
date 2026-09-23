#!/usr/bin/env bash
# Attachment isolation tests: MNP-017.
# Requires 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_topology

log "MNP-017: policy-for=test-net-a must not affect test-net-b or the primary network"
apply_static "${POLICIES_DIR}/static/mnp-017-policy-for-test-net-a.yaml"
wait_reconcile mnp-test-a mnp-policy-for-test-net-a

assert "test-net-a: client-b -> server TCP 8080 (target attachment, denied)" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
assert "test-net-b: client -> server TCP 8080 over test-net-b (unaffected, client-b has no test-net-b interface)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_B}" 8080)"

info "checking the primary network is unaffected: connect to the server's primary Pod IP"
PRIMARY_IP="$(kubectl get pod -n mnp-test-a server -o jsonpath='{.status.podIP}')"
assert "primary network: client -> server TCP 8080 via primary Pod IP (unaffected)" allow "$(repeat_check tcp_check mnp-test-a client "${PRIMARY_IP}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-017-policy-for-test-net-a.yaml"

log "MNP-017: policy-for referencing a non-existent attachment must not affect any interface"
apply_static "${POLICIES_DIR}/static/mnp-017-policy-for-nonexistent.yaml"
wait_reconcile mnp-test-a mnp-policy-for-nonexistent
assert "test-net-a unaffected by a policy for a non-existent attachment" allow "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
assert "primary network unaffected by a policy for a non-existent attachment" allow "$(repeat_check tcp_check mnp-test-a client "${PRIMARY_IP}" 8080)"

info "controller log excerpt for the non-existent attachment (inspect manually for a clear, actionable error/warning):"
kubectl logs -n kube-system -l name=multi-networkpolicy-nftables --since=1m --tail=50 | grep -i "does-not-exist\|error\|warn" || info "(no matching log lines found - check full controller logs manually)"
delete_static "${POLICIES_DIR}/static/mnp-017-policy-for-nonexistent.yaml"

summary
