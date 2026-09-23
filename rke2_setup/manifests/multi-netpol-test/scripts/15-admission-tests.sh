#!/usr/bin/env bash
# CRD admission tests: MNP-001 through MNP-004.
# Does not require the topology or workloads to be deployed.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

log "MNP-001: minimal valid policy is accepted and persisted"
apply_static "${POLICIES_DIR}/static/mnp-001-minimal.yaml"
if kubectl get multi-networkpolicies.k8s.cni.cncf.io -n mnp-test-a mnp-001-minimal >/dev/null 2>&1; then
  pass_line "MNP-001: minimal policy persisted"
else
  fail_line "MNP-001: minimal policy not found after apply"
fi
if kubectl get multi-policy -n mnp-test-a mnp-001-minimal >/dev/null 2>&1; then
  pass_line "MNP-001: short name 'multi-policy' resolves"
else
  fail_line "MNP-001: short name 'multi-policy' did not resolve"
fi
delete_static "${POLICIES_DIR}/static/mnp-001-minimal.yaml"

log "MNP-002: policy without spec.podSelector is rejected"
apply_invalid_expect_rejection "${POLICIES_DIR}/invalid/mnp-002-missing-podselector.yaml" "MNP-002 missing podSelector"

log "MNP-003: structural schema violations are rejected"
apply_invalid_expect_rejection "${POLICIES_DIR}/invalid/mnp-003-ingress-not-array.yaml" "MNP-003 ingress not array"
apply_invalid_expect_rejection "${POLICIES_DIR}/invalid/mnp-003-protocol-not-string.yaml" "MNP-003 protocol not string"
apply_invalid_expect_rejection "${POLICIES_DIR}/invalid/mnp-003-ipblock-missing-cidr.yaml" "MNP-003 ipBlock missing cidr"
apply_invalid_expect_rejection "${POLICIES_DIR}/invalid/mnp-003-selector-missing-operator.yaml" "MNP-003 selector missing operator"

log "MNP-004: semantic (cross-field) violations - outcome not guaranteed by schema, recording actual behavior"
for f in mnp-004-endport-lower-than-port mnp-004-endport-named-port mnp-004-ipblock-with-podselector; do
  out="$(kubectl apply -f "${POLICIES_DIR}/invalid/${f}.yaml" 2>&1)"
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    na_line "MNP-004 ${f}: rejected by API server -- ${out}"
  else
    na_line "MNP-004 ${f}: ACCEPTED by API server (schema does not enforce this constraint); inspect controller logs/nftables output to see whether it silently ignored the invalid field"
  fi
done
# Clean up any that were accepted.
kubectl delete -f "${POLICIES_DIR}/invalid/mnp-004-endport-lower-than-port.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete -f "${POLICIES_DIR}/invalid/mnp-004-endport-named-port.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete -f "${POLICIES_DIR}/invalid/mnp-004-ipblock-with-podselector.yaml" --ignore-not-found=true >/dev/null 2>&1 || true

summary
