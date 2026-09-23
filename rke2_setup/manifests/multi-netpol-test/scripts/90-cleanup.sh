#!/usr/bin/env bash
# Deletes all MultiNetworkPolicy objects first (to let the controller
# reconcile them away cleanly), then the test workloads, attachments, and
# namespaces. Does not remove the CRD or controller Deployment/DaemonSet -
# pass --all to also remove those.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

log "Deleting any MultiNetworkPolicy objects"
kubectl delete multi-networkpolicies.k8s.cni.cncf.io --all -n mnp-test-a --ignore-not-found=true
kubectl delete multi-networkpolicies.k8s.cni.cncf.io --all -n mnp-test-b --ignore-not-found=true
sleep 3

log "Deleting test namespaces (also removes workloads and NetworkAttachmentDefinitions)"
kubectl delete namespace mnp-test-a mnp-test-b --ignore-not-found=true

rm -f "${TOPOLOGY_ENV}"

if [[ "${1:-}" == "--all" ]]; then
  log "Removing the shared controller and CRD (--all was passed)"
  MANIFESTS_DIR="$(cd "${ROOT_DIR}/.." && pwd)"
  kubectl delete -f "${MANIFESTS_DIR}/deploy-multi-netpol.yaml" --ignore-not-found=true
  kubectl delete -f "${MANIFESTS_DIR}/scheme-multi-netpol.yaml" --ignore-not-found=true
else
  info "Controller and CRD left in place. Re-run with --all to remove them too."
fi

echo
echo "Cleanup complete."
