#!/usr/bin/env bash
# Deletes all MultiNetworkPolicy objects first (to let the controller
# reconcile them away cleanly), then the test workloads, attachments, and
# namespaces. Leaves the chart under test installed - pass --all to also
# roll the rke2-multus release back to the revision it had before
# 00-install-chart.sh (or uninstall it if there was none) and remove the
# MultiNetworkPolicy CRD if the kit applied it.
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
  require_helm
  load_chart_state
  if [[ -n "${PREV_REVISION}" ]]; then
    log "Rolling ${HELM_RELEASE} back to revision ${PREV_REVISION} (--all was passed)"
    helm rollback "${HELM_RELEASE}" "${PREV_REVISION}" -n "${HELM_NAMESPACE}" --wait --timeout 5m
  else
    log "Uninstalling ${HELM_RELEASE}, which did not exist before the test (--all was passed)"
    helm uninstall "${HELM_RELEASE}" -n "${HELM_NAMESPACE}" --wait --timeout 5m
  fi
  if [[ "${CRD_APPLIED}" == 1 ]]; then
    log "Removing the MultiNetworkPolicy CRD applied by 00-install-chart.sh"
    kubectl delete crd multi-networkpolicies.k8s.cni.cncf.io --ignore-not-found=true
  fi
  rm -f "${CHART_STATE_ENV}"
else
  info "Chart under test left in place. Re-run with --all to roll the ${HELM_RELEASE} release back."
fi

echo
echo "Cleanup complete."
