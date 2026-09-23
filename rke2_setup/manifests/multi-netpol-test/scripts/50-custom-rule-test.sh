#!/usr/bin/env bash
# Custom nftables rule interaction test: MNP-020.
# Adds a rule for TCP 9999 to the controller's custom-v4-rules ConfigMap,
# restarts the controller DaemonSet, tests before/after a matching
# MultiNetworkPolicy, then restores the original ConfigMap. Requires
# 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_topology

CM_NAME="multi-networkpolicy-custom-v4-rules"
CM_NS="kube-system"
BACKUP_FILE="${RESULTS_DIR}/${CM_NAME}.backup.yaml"

log "MNP-020: backing up ${CM_NAME}"
kubectl get configmap -n "${CM_NS}" "${CM_NAME}" -o yaml > "${BACKUP_FILE}"
info "backup saved to ${BACKUP_FILE}"

restore_configmap() {
  info "restoring original ${CM_NAME}"
  kubectl apply -f "${BACKUP_FILE}" >/dev/null
  kubectl rollout restart daemonset/multi-networkpolicy-nftables -n "${CM_NS}" >/dev/null
  kubectl rollout status -n "${CM_NS}" daemonset/multi-networkpolicy-nftables --timeout=180s >/dev/null
}
trap restore_configmap EXIT

log "Adding a custom rule that blocks TCP 9999 (a port unused by any test workload)"
kubectl patch configmap -n "${CM_NS}" "${CM_NAME}" --type merge -p \
  '{"data":{"custom-v4-rules.txt":"# e2e MNP-020 custom rule\ntcp dport 9999 drop\n"}}'
kubectl rollout restart daemonset/multi-networkpolicy-nftables -n "${CM_NS}"
kubectl rollout status -n "${CM_NS}" daemonset/multi-networkpolicy-nftables --timeout=180s
wait_reconcile

log "Adding a temporary listener on port 9999 on the server pod"
kubectl exec -n mnp-test-a server -- sh -c \
  "nohup socat -T2 TCP-LISTEN:9999,reuseaddr,fork SYSTEM:'printf \"ok\\n\"' >/tmp/9999.log 2>&1 &"
sleep 2

assert "no MultiNetworkPolicy present, custom rule blocks TCP 9999" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 9999)"
assert "no MultiNetworkPolicy present, TCP 8080 is still open (custom rule is port-specific)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

log "Applying mnp-020-custom-rule-allow.yaml (allows only TCP 8080 from app=client)"
apply_static "${POLICIES_DIR}/static/mnp-020-custom-rule-allow.yaml"
wait_reconcile mnp-test-a mnp-custom-rule-allow
assert "with policy present, TCP 9999 still blocked by the custom rule" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 9999)"
assert "with policy present, TCP 8080 remains allowed for app=client" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "with policy present, TCP 8081 is denied (no MultiNetworkPolicy rule for it)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"
delete_static "${POLICIES_DIR}/static/mnp-020-custom-rule-allow.yaml"

summary
