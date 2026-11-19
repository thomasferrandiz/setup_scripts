#!/usr/bin/env bash
# Runs the full MultiNetworkPolicy test suite against the rke2-multus chart
# given as the first argument (or CHART_TGZ) and prints a final summary.
# Does not run cleanup automatically - run 90-cleanup.sh yourself
# afterward. Set SKIP_INSTALL=1 to skip 00-install-chart.sh if the chart
# under test is already deployed, and SKIP_TOPOLOGY=1 to skip
# 10-deploy-topology.sh if the topology is already up with a valid
# results/topology.env.
set -uo pipefail
DIR="$(dirname "$0")"
CHART_TGZ="${1:-${CHART_TGZ:-}}"
export CHART_TGZ

FAILED_STAGES=()

run_stage() {
  local script="$1"
  echo
  echo "################################################################"
  echo "# Running ${script}"
  echo "################################################################"
  if bash "${DIR}/${script}"; then
    :
  else
    FAILED_STAGES+=("${script}")
  fi
}

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  run_stage "00-install-chart.sh"
  if [[ "${#FAILED_STAGES[@]}" -ne 0 ]]; then
    echo "Chart installation failed, not running the test stages." >&2
    exit 1
  fi
fi
run_stage "05-prime-render-test.sh"
[[ "${SKIP_TOPOLOGY:-0}" == "1" ]] || run_stage "10-deploy-topology.sh"

run_stage "15-admission-tests.sh"
run_stage "20-ingress-tests.sh"
run_stage "25-egress-tests.sh"
run_stage "30-policytype-and-union-tests.sh"
run_stage "35-lifecycle-tests.sh"
run_stage "40-isolation-tests.sh"
run_stage "42-networkpolicy-coexistence-test.sh"
run_stage "45-node-recovery-tests.sh"
run_stage "50-custom-rule-test.sh"
run_stage "55-network-plugins-test.sh"
run_stage "60-icmp-test.sh"
run_stage "65-prime-images-test.sh"

echo
echo "################################################################"
if [[ "${#FAILED_STAGES[@]}" -eq 0 ]]; then
  echo "# All stages completed without a failing assertion."
else
  echo "# Stages with at least one failing assertion:"
  for s in "${FAILED_STAGES[@]}"; do
    echo "#   - ${s}"
  done
fi
echo "################################################################"
echo
echo "Run ${DIR}/90-cleanup.sh when done (add --all to also roll the rke2-multus release back)."

[[ "${#FAILED_STAGES[@]}" -eq 0 ]]
