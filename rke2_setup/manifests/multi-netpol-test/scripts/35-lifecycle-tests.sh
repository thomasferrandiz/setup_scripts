#!/usr/bin/env bash
# Reconciliation-after-change tests: MNP-015 (label changes) and MNP-016
# (policy update/delete lifecycle). Requires 10-deploy-topology.sh to have
# run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_topology

log "MNP-015: reconciliation after label changes"
apply_static "${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"
wait_reconcile mnp-test-a mnp-ingress-allow-client
assert "initial: client -> server TCP 8080" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

info "relabeling server so it no longer matches the policy's podSelector (app=server -> app=server-unselected)"
kubectl label pod -n mnp-test-a server app=server-unselected --overwrite
wait_reconcile
assert "server no longer selected -> ingress unrestricted (allow)" allow "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"

info "restoring server label"
kubectl label pod -n mnp-test-a server app=server --overwrite
wait_reconcile
assert "server re-selected -> deny restored for client-b" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"

info "relabeling client so it no longer matches the allowed peer (app=client -> app=client-temp)"
kubectl label pod -n mnp-test-a client app=client-temp --overwrite
wait_reconcile
assert "relabeled client no longer matches peer selector -> deny" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

info "restoring client label"
kubectl label pod -n mnp-test-a client app=client --overwrite
wait_reconcile
assert "client label restored -> allow restored" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

delete_static "${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"
apply_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"
apply_static "${POLICIES_DIR}/static/mnp-008-ingress-allow-ns-and-pod.yaml"
wait_reconcile mnp-test-a mnp-ingress-allow-ns-and-pod
assert "client-other-ns in mnp-test=false namespace -> denied" deny "$(repeat_check tcp_check mnp-test-b client-other-ns "${SERVER_IP_A}" 8080)"

info "flipping mnp-test-b namespace label mnp-test=false -> true"
kubectl label namespace mnp-test-b mnp-test=true --overwrite
wait_reconcile
assert "client-other-ns now in a mnp-test=true namespace -> allowed" allow "$(repeat_check tcp_check mnp-test-b client-other-ns "${SERVER_IP_A}" 8080)"

info "restoring mnp-test-b namespace label to false"
kubectl label namespace mnp-test-b mnp-test=false --overwrite
wait_reconcile
assert "namespace label restored -> denied again" deny "$(repeat_check tcp_check mnp-test-b client-other-ns "${SERVER_IP_A}" 8080)"

delete_static "${POLICIES_DIR}/static/mnp-008-ingress-allow-ns-and-pod.yaml"
delete_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"

log "MNP-016: policy update and delete lifecycle"
apply_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"
wait_reconcile mnp-test-a mnp-ingress-deny-all
assert "step 1: deny-all in place" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

info "updating the same policy object (kubectl apply) to allow TCP 8080 from app=client"
apply_static "${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"
wait_reconcile mnp-test-a mnp-ingress-allow-client
assert "step 2: after update, client -> server TCP 8080 allowed" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

info "updating back to deny-all"
delete_static "${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"
wait_reconcile
assert "step 3: back to deny-all" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

info "deleting the final selecting policy"
delete_static "${POLICIES_DIR}/static/mnp-006-ingress-deny-all.yaml"
wait_reconcile
assert "step 4: no policy selects server -> baseline (allow) restored" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

summary
