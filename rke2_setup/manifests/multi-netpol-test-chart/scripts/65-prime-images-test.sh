#!/usr/bin/env bash
# P1 (on cluster): upgrades the release with global.prime.enabled=true and
# global.systemDefaultRegistry=PRIME_REGISTRY, as RKE2 Prime sets them, then
# also enables the dynamic networks controller (DNC, which needs the thick
# plugin the suite runs with) and checks that the mnp controller and the DNC
# run the hardened primeRepository:primeTag images pulled from
# PRIME_REGISTRY, that every DaemonSet of the release uses that registry, and
# that the hardened controller enforces MNP-007. Rolls the release back to
# its previous revision at the end.
# PRIME_REGISTRY must serve the images without credentials (default
# registry.rancher.com, which allows anonymous pulls).
# Requires 00-install-chart.sh and 10-deploy-topology.sh to have run first.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_helm
load_topology
load_chart_state

PRIME_REGISTRY="${PRIME_REGISTRY:-registry.rancher.com}"
POLICY_FILE="${POLICIES_DIR}/static/mnp-007-ingress-allow-client.yaml"
POLICY_NAME="mnp-ingress-allow-client"
VALUES_FILE="${RESULTS_DIR}/prime-values.json"

# release_daemonsets
# Prints the names of the DaemonSets owned by the release (subcharts included).
release_daemonsets() {
  kubectl get daemonset -n "${HELM_NAMESPACE}" -o json | jq -r --arg r "${HELM_RELEASE}" \
    '.items[] | select(.metadata.annotations["meta.helm.sh/release-name"] == $r) | .metadata.name'
}

# ds_images DAEMONSET
# Prints the init and regular container images of the DaemonSet pod template.
ds_images() {
  kubectl get daemonset -n "${HELM_NAMESPACE}" "$1" -o json \
    | jq -r '.spec.template.spec | ((.initContainers // []) + .containers)[] | "\(.name)=\(.image)"'
}

wait_release_rollout() {
  local ds
  for ds in $(release_daemonsets); do
    kubectl rollout status -n "${HELM_NAMESPACE}" "daemonset/${ds}" --timeout=300s >/dev/null \
      || fail_line "DaemonSet ${ds} did not finish rolling out"
  done
}

# check_controller_pods DAEMONSET CONTAINER IMAGE
# Every pod of the DaemonSet must run CONTAINER from IMAGE, ready, with an
# image ID resolved from PRIME_REGISTRY (i.e. the image was pulled from it).
check_controller_pods() {
  local ds="$1" container="$2" image="$3" selector bad
  selector="$(kubectl get daemonset -n "${HELM_NAMESPACE}" "${ds}" -o json \
    | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
  bad="$(kubectl get pods -n "${HELM_NAMESPACE}" -l "${selector}" -o json | jq -r \
    --arg c "${container}" --arg img "${image}" --arg reg "${PRIME_REGISTRY}/" '
    .items[] | select(.metadata.deletionTimestamp == null) | .metadata.name as $pod
    | (.status.containerStatuses // [])[] | select(.name == $c)
    | select(.image != $img or .ready != true or (.imageID | startswith($reg) | not))
    | "\($pod): image=\(.image) ready=\(.ready) imageID=\(.imageID)"')"
  if [[ -z "${bad}" ]]; then
    pass_line "${ds} pods run ${image} (ready, image ID from ${PRIME_REGISTRY})"
  else
    fail_line "${ds} pods not running ${image} from ${PRIME_REGISTRY}: ${bad//$'\n'/; }"
  fi
}

# check_ds_image DAEMONSET CONTAINER EXPECTED
check_ds_image() {
  local actual
  actual="$(ds_images "$1" | awk -F= -v c="$2" '$1 == c { print $2 }')"
  if [[ "${actual}" == "$3" ]]; then
    pass_line "${1}/${2} image is $3"
  else
    fail_line "${1}/${2} image should be $3 (got: ${actual:-none})"
  fi
}

SAVED_REVISION="$(helm status "${HELM_RELEASE}" -n "${HELM_NAMESPACE}" -o json | jq -r '.version')"
SAVED_IMAGES="$(for ds in $(release_daemonsets); do ds_images "${ds}" | sed "s|^|${ds}/|"; done | sort)"
RESTORED=0
restore_release() {
  [[ "${RESTORED}" == 1 ]] && return
  RESTORED=1
  info "helm rollback ${HELM_RELEASE} to revision ${SAVED_REVISION}"
  helm rollback "${HELM_RELEASE}" "${SAVED_REVISION}" -n "${HELM_NAMESPACE}" --wait --timeout 5m >/dev/null
  wait_release_rollout
}
trap 'delete_static "${POLICY_FILE}"; restore_release' EXIT

MNP_IMAGE="${PRIME_REGISTRY}/$(chart_default multiNetworkPolicy primeRepository):$(chart_default multiNetworkPolicy primeTag)"
DNC_IMAGE="${PRIME_REGISTRY}/$(chart_default dynamicNetworksController primeRepository):$(chart_default dynamicNetworksController primeTag)"

log "P1: upgrading ${HELM_RELEASE} (revision ${SAVED_REVISION}) with prime enabled, systemDefaultRegistry=${PRIME_REGISTRY}"
TEST_DNC=0
multus_is_thick && TEST_DNC=1
jq -n --arg reg "${PRIME_REGISTRY}" --argjson dnc "$([[ "${TEST_DNC}" == 1 ]] && echo true || echo false)" '
  {global: {prime: {enabled: true}, systemDefaultRegistry: $reg}}
  + if $dnc then {dynamicNetworksController: {enabled: true}} else {} end' > "${VALUES_FILE}"
if helm_upgrade_chart "${CHART_TGZ}" -f "${VALUES_FILE}" --wait --timeout 5m >/dev/null; then
  pass_line "helm upgrade with prime enabled succeeded"
else
  fail_line "helm upgrade with prime enabled failed"
fi
wait_release_rollout

log "P1: hardened controller images"
check_ds_image "${CONTROLLER_DAEMONSET}" "${CONTROLLER_CONTAINER}" "${MNP_IMAGE}"
check_controller_pods "${CONTROLLER_DAEMONSET}" "${CONTROLLER_CONTAINER}" "${MNP_IMAGE}"
if [[ "${TEST_DNC}" == 1 ]]; then
  DNC_DS="${HELM_RELEASE}-dnc"
  DNC_CONTAINER="$(ds_images "${DNC_DS}" | awk -F= -v img="${DNC_IMAGE}" '$2 == img { print $1; exit }')"
  check_ds_image "${DNC_DS}" "${DNC_CONTAINER:-dynamic-networks-controller}" "${DNC_IMAGE}"
  [[ -n "${DNC_CONTAINER}" ]] && check_controller_pods "${DNC_DS}" "${DNC_CONTAINER}" "${DNC_IMAGE}"
else
  na_line "dynamic networks controller not tested: the release does not run the thick plugin"
fi

log "P1: every release DaemonSet uses ${PRIME_REGISTRY}"
OFF_REGISTRY="$(for ds in $(release_daemonsets); do ds_images "${ds}" | sed "s|^|${ds}/|"; done \
  | awk -F= -v reg="${PRIME_REGISTRY}/" 'index($2, reg) != 1')"
if [[ -z "${OFF_REGISTRY}" ]]; then
  pass_line "all release DaemonSet images come from ${PRIME_REGISTRY}"
else
  fail_line "images outside ${PRIME_REGISTRY}: ${OFF_REGISTRY//$'\n'/; }"
fi

log "P1: MNP-007 enforced by the hardened controller"
apply_static "${POLICY_FILE}"
wait_reconcile mnp-test-a "${POLICY_NAME}"
assert "prime: client -> server TCP 8080 (allowed)" allow "$(repeat_check tcp_check mnp-test-a client "${SERVER_IP_A}" 8080)"
assert "prime: client-b -> server TCP 8080 (denied)" deny "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"
delete_static "${POLICY_FILE}"

log "P1: rolling back to revision ${SAVED_REVISION}"
restore_release
RESTORED_IMAGES="$(for ds in $(release_daemonsets); do ds_images "${ds}" | sed "s|^|${ds}/|"; done | sort)"
if [[ "${RESTORED_IMAGES}" == "${SAVED_IMAGES}" ]]; then
  pass_line "release DaemonSet images restored"
else
  fail_line "release DaemonSet images differ after rollback: $(diff <(echo "${SAVED_IMAGES}") <(echo "${RESTORED_IMAGES}") | tr '\n' ' ')"
fi
wait_reconcile
assert "rolled back: client-b -> server TCP 8080 (no policy)" allow "$(repeat_check tcp_check mnp-test-a client-b "${SERVER_IP_A}" 8080)"

summary
