#!/usr/bin/env bash
# P1 (render only): with global.prime.enabled=true, as RKE2 Prime sets it,
# the mnp and dynamic networks controller (DNC) DaemonSets must use the
# hardened images (primeRepository:primeTag) prefixed with
# global.systemDefaultRegistry. Renders the chart with helm template and
# never touches the cluster. Usage: 05-prime-render-test.sh [CHART_TGZ]
# (defaults to CHART_TGZ, then to the tarball recorded by 00-install-chart.sh).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_helm

CHART_TGZ="${1:-${CHART_TGZ:-}}"
if [[ -z "${CHART_TGZ}" && -f "${CHART_STATE_ENV}" ]]; then
  load_chart_state
fi
if [[ ! -f "${CHART_TGZ}" ]]; then
  echo "ERROR: chart tarball not found: '${CHART_TGZ}'. Pass it as the first argument or set CHART_TGZ." >&2
  exit 1
fi
PRIME_TEST_REGISTRY="${PRIME_TEST_REGISTRY:-registry.example.com}"

# rendered_image TEMPLATE HELM_ARGS...
# Renders TEMPLATE with mnp and DNC enabled (DNC needs the thick plugin and
# its ConfigMap) and prints its container image.
rendered_image() {
  local template="$1"; shift
  helm template "${HELM_RELEASE}" "${CHART_TGZ}" --namespace "${HELM_NAMESPACE}" \
    --set multiNetworkPolicy.enabled=true \
    --set dynamicNetworksController.enabled=true \
    --set thickPlugin.enabled=true \
    --set manifests.configMap=true \
    "$@" --show-only "${template}" \
    | awk '$1 == "image:" || ($1 == "-" && $2 == "image:") { gsub(/"/, "", $NF); print $NF }'
}

# check_images CASE REGISTRY_PREFIX REPO_KEY TAG_KEY HELM_ARGS...
check_images() {
  local case="$1" prefix="$2" repo_key="$3" tag_key="$4"; shift 4
  local section template repo tag expected actual
  for section in multiNetworkPolicy dynamicNetworksController; do
    template="templates/${section}.yaml"
    repo="$(chart_default "${section}" "${repo_key}")"
    tag="$(chart_default "${section}" "${tag_key}")"
    if [[ -z "${repo}" || -z "${tag}" ]]; then
      fail_line "${case}: chart has no ${section}.image.${repo_key}/${tag_key} default"
      continue
    fi
    expected="${prefix}${repo}:${tag}"
    actual="$(rendered_image "${template}" "$@" 2>&1)"
    if [[ "${actual}" == "${expected}" ]]; then
      pass_line "${case}: ${section} image is ${expected}"
    else
      fail_line "${case}: ${section} image should be ${expected} (got: ${actual})"
    fi
  done
}

log "P1: rendering ${CHART_TGZ##*/} with helm template"
check_images "prime + systemDefaultRegistry=${PRIME_TEST_REGISTRY}" "${PRIME_TEST_REGISTRY}/" primeRepository primeTag \
  --set global.prime.enabled=true --set "global.systemDefaultRegistry=${PRIME_TEST_REGISTRY}"
check_images "prime, no systemDefaultRegistry" "" primeRepository primeTag \
  --set global.prime.enabled=true
check_images "no prime + systemDefaultRegistry=${PRIME_TEST_REGISTRY} (mirrored images)" "${PRIME_TEST_REGISTRY}/" repository tag \
  --set global.prime.enabled=false --set "global.systemDefaultRegistry=${PRIME_TEST_REGISTRY}"

summary
