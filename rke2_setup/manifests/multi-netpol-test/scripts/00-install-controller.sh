#!/usr/bin/env bash
# Installs the MultiNetworkPolicy CRD and the nftables-based controller,
# then waits for both to become ready. Corresponds to the "Common setup"
# section, step 1-2, of multi-network-policy-test-plan.md.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

MANIFESTS_DIR="$(cd "${ROOT_DIR}/.." && pwd)"

log "Applying MultiNetworkPolicy CRD"
kubectl apply -f "${MANIFESTS_DIR}/scheme-multi-netpol.yaml"

log "Applying multi-networkpolicy-nftables controller"
kubectl apply -f "${MANIFESTS_DIR}/deploy-multi-netpol.yaml"

log "Waiting for controller DaemonSet rollout"
kubectl rollout status -n kube-system daemonset/multi-networkpolicy-nftables --timeout=180s

log "Verifying CRD discovery"
kubectl get crd multi-networkpolicies.k8s.cni.cncf.io
kubectl api-resources --api-group=k8s.cni.cncf.io

log "Controller pods"
kubectl get pods -n kube-system -l name=multi-networkpolicy-nftables -o wide

echo
echo "Controller installed and ready."
