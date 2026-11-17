#!/usr/bin/env bash
# Custom nftables rule interaction test: MNP-020.
# Sets multiNetworkPolicy.customRules.ingress.v4 to a rule dropping TCP 9999
# through a helm upgrade of the chart under test, checks that the chart
# wires it up (ConfigMap key, ingress-only flag, checksum-triggered pod
# rollout), tests before/after a matching MultiNetworkPolicy, then restores
# the previous value. Requires 00-install-chart.sh and
# 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_helm
load_topology
load_chart_state

RULE_FILE_IN_POD="/etc/multi-networkpolicy/rules/custom-v4-ingress-rules.txt"
RULE_VALUES="${RESULTS_DIR}/mnp-020-custom-rule-values.json"
RESTORE_VALUES="${RESULTS_DIR}/mnp-020-restore-values.json"

controller_pods() {
  kubectl get pods -n "${CONTROLLER_NAMESPACE}" -l "${CONTROLLER_LABEL_SELECTOR}" \
    -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort
}
template_checksum() {
  kubectl get daemonset -n "${CONTROLLER_NAMESPACE}" "${CONTROLLER_DAEMONSET}" -o json \
    | jq -r '.spec.template.metadata.annotations["checksum/custom-rules"] // ""'
}
controller_args() {
  kubectl get daemonset -n "${CONTROLLER_NAMESPACE}" "${CONTROLLER_DAEMONSET}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="'"${CONTROLLER_CONTAINER}"'")].args}'
}

# JSON is valid YAML, so jq-built files can be passed to helm with -f and
# multi-line rules need no --set escaping.
helm get values "${HELM_RELEASE}" -n "${HELM_NAMESPACE}" -o json \
  | jq '{multiNetworkPolicy: {customRules: {ingress: {v4: (.multiNetworkPolicy.customRules.ingress.v4 // "")}}}}' \
  > "${RESTORE_VALUES}"
jq -n '{multiNetworkPolicy: {customRules: {ingress: {v4: "# e2e MNP-020 custom rule\ntcp dport 9999 drop\n"}}}}' \
  > "${RULE_VALUES}"

RESTORED=0
restore_values() {
  [[ "${RESTORED}" == 1 ]] && return
  RESTORED=1
  info "restoring previous multiNetworkPolicy.customRules.ingress.v4"
  helm_upgrade_chart "${CHART_TGZ}" -f "${RESTORE_VALUES}" >/dev/null
  wait_controller_rollout >/dev/null
}
trap restore_values EXIT

log "MNP-020: setting customRules.ingress.v4 (drop TCP 9999, a port unused by any test workload) via helm upgrade"
PODS_BEFORE="$(controller_pods)"
CHECKSUM_BEFORE="$(template_checksum)"
helm_upgrade_chart "${CHART_TGZ}" -f "${RULE_VALUES}"
wait_controller_rollout

CM_RULES="$(kubectl get configmap -n "${CONTROLLER_NAMESPACE}" "${CUSTOM_RULES_CM}" \
  -o jsonpath='{.data.custom-v4-ingress-rules\.txt}' 2>/dev/null)"
if [[ "${CM_RULES}" == *"tcp dport 9999 drop"* ]]; then
  pass_line "ConfigMap ${CUSTOM_RULES_CM} has the rule under custom-v4-ingress-rules.txt"
else
  fail_line "ConfigMap ${CUSTOM_RULES_CM} missing custom-v4-ingress-rules.txt with the rule (got: '${CM_RULES}')"
fi
CM_KEYS="$(kubectl get configmap -n "${CONTROLLER_NAMESPACE}" "${CUSTOM_RULES_CM}" -o json 2>/dev/null | jq -r '.data // {} | keys | join(",")')"
if [[ "${CM_KEYS}" == "custom-v4-ingress-rules.txt" ]]; then
  pass_line "ConfigMap only carries the ingress v4 rule file (keys: ${CM_KEYS})"
else
  fail_line "ConfigMap should only carry custom-v4-ingress-rules.txt (keys: ${CM_KEYS})"
fi

ARGS="$(controller_args)"
if [[ "${ARGS}" == *"--custom-v4-ingress-rule-file=${RULE_FILE_IN_POD}"* ]]; then
  pass_line "controller started with --custom-v4-ingress-rule-file=${RULE_FILE_IN_POD}"
else
  fail_line "controller args lack --custom-v4-ingress-rule-file=${RULE_FILE_IN_POD} (args: ${ARGS})"
fi
if [[ "${ARGS}" != *"egress-rule-file"* && "${ARGS}" != *"custom-v6-"* ]]; then
  pass_line "no egress or v6 custom rule file flag for an ingress.v4-only rule"
else
  fail_line "unexpected egress/v6 custom rule file flag (args: ${ARGS})"
fi

CHECKSUM_AFTER="$(template_checksum)"
if [[ -n "${CHECKSUM_AFTER}" && "${CHECKSUM_AFTER}" != "${CHECKSUM_BEFORE}" ]]; then
  pass_line "pod template checksum/custom-rules annotation changed (${CHECKSUM_BEFORE:-none} -> ${CHECKSUM_AFTER})"
else
  fail_line "pod template checksum/custom-rules annotation did not change (before='${CHECKSUM_BEFORE}', after='${CHECKSUM_AFTER}')"
fi
PODS_AFTER="$(controller_pods)"
if [[ -n "${PODS_AFTER}" && -z "$(comm -12 <(echo "${PODS_BEFORE}") <(echo "${PODS_AFTER}"))" ]]; then
  pass_line "all controller pods were replaced by the helm upgrade alone (no manual restart)"
else
  fail_line "some controller pods were not replaced after the custom rule change (before: ${PODS_BEFORE//$'\n'/ }, after: ${PODS_AFTER//$'\n'/ })"
fi
wait_reconcile

log "Adding a temporary listener on port 9999 on the server pod"
kubectl exec -n mnp-test-a server -- sh -c \
  "nohup socat -T2 TCP-LISTEN:9999,reuseaddr,fork SYSTEM:'printf \"ok\\n\"' >/tmp/9999.log 2>&1 &"
sleep 2

# Custom rules are only ever programmed into a pod's nftables chains as a
# side effect of that pod being matched by at least one MultiNetworkPolicy
# (ensureBasicStructure/createCommonRules only run from inside
# enforcePolicy, after the pod-selector match check - the controller never
# proactively syncs common rules to unmatched pods). With no policy
# selecting "server" yet, TCP 9999 is correctly wide open here; the
# meaningful "does the custom rule still apply" check happens below, once a
# policy is present.
assert "no MultiNetworkPolicy present, TCP 9999 is open (custom rule only applies to policy-matched pods)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 9999)"
assert "no MultiNetworkPolicy present, TCP 8080 is still open (custom rule is port-specific)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"

log "Applying mnp-020-custom-rule-allow.yaml (allows only TCP 8080 from app=client)"
apply_static "${POLICIES_DIR}/static/mnp-020-custom-rule-allow.yaml"
wait_reconcile mnp-test-a mnp-custom-rule-allow
assert "with policy present, TCP 9999 still blocked by the custom rule" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 9999)"
assert "with policy present, TCP 8080 remains allowed for app=client" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "with policy present, TCP 8081 is denied (no MultiNetworkPolicy rule for it)" deny "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8081)"

log "MNP-020: restoring the previous custom rules via helm upgrade"
restore_values
if [[ "$(jq -r '.multiNetworkPolicy.customRules.ingress.v4' "${RESTORE_VALUES}")" == "" ]]; then
  if kubectl get configmap -n "${CONTROLLER_NAMESPACE}" "${CUSTOM_RULES_CM}" >/dev/null 2>&1; then
    fail_line "ConfigMap ${CUSTOM_RULES_CM} still exists after removing all custom rules"
  else
    pass_line "ConfigMap ${CUSTOM_RULES_CM} removed once no custom rules are set"
  fi
  if [[ "$(controller_args)" != *"rule-file"* ]]; then
    pass_line "custom rule file flags removed from the controller args"
  else
    fail_line "custom rule file flags still present after removing all custom rules"
  fi
fi
delete_static "${POLICIES_DIR}/static/mnp-020-custom-rule-allow.yaml"

summary
