#!/usr/bin/env bash
# Cross-node enforcement and controller-recovery tests: MNP-018.
# Requires 10-deploy-topology.sh to have run first. The workload manifest
# sets a preferred podAntiAffinity between role=server and role=client, so
# on multi-node clusters they typically land on different nodes already;
# this script verifies that and, if not achieved, reports it rather than
# forcing scheduling (forcing would require cluster-specific nodeName
# values this kit cannot know in advance).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_topology

SERVER_NODE="$(kubectl get pod -n mnp-test-a server -o jsonpath='{.spec.nodeName}')"
CLIENT_NODE="$(kubectl get pod -n mnp-test-a client -o jsonpath='{.spec.nodeName}')"
info "server node: ${SERVER_NODE}, client node: ${CLIENT_NODE}"
if [[ "${SERVER_NODE}" == "${CLIENT_NODE}" ]]; then
  na_line "MNP-018: server and client landed on the same node (${SERVER_NODE}); cluster may be single-node. Cross-node enforcement not exercised - repeat manually with nodeSelector/nodeName pinning on a multi-node cluster if this matters for your environment."
else
  pass_line "MNP-018: server (${SERVER_NODE}) and client (${CLIENT_NODE}) are on different nodes"
fi

log "MNP-018: repeat MNP-007 (ingress allow) across nodes"
apply_static "${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"
wait_reconcile mnp-test-a mnp-ingress-allow-client
assert "cross-node: client (allowed) -> server TCP 8080" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "cross-node: client-b (denied) -> server TCP 8080" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
delete_static "${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"

log "MNP-018: repeat MNP-012 (egress allow) across nodes"
apply_static "${POLICIES_DIR}/static/mnp-011-egress-deny-all.yaml"
apply_static "${POLICIES_DIR}/static/mnp-012-egress-allow-podselector.yaml"
wait_reconcile mnp-test-a mnp-egress-allow-podselector
assert "cross-node: client->server TCP 8080 egress (permitted)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "cross-node: client->server TCP 8081 egress (not permitted)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"

log "MNP-018: restart one controller DaemonSet pod during enforcement, then re-check"
CTRL_POD="$(kubectl get pods -n kube-system -l name=multi-networkpolicy-nftables -o jsonpath='{.items[0].metadata.name}')"
info "deleting controller pod ${CTRL_POD} to force a restart"
kubectl delete pod -n kube-system "${CTRL_POD}" --wait=false
kubectl rollout status -n kube-system daemonset/multi-networkpolicy-nftables --timeout=180s
wait_reconcile mnp-test-a mnp-egress-allow-podselector
assert "post-restart: enforcement unchanged, client->server TCP 8080 (permitted)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "post-restart: enforcement unchanged, client->server TCP 8081 (not permitted)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"

delete_static "${POLICIES_DIR}/static/mnp-012-egress-allow-podselector.yaml"
delete_static "${POLICIES_DIR}/static/mnp-011-egress-deny-all.yaml"

summary
