#!/usr/bin/env bash
# Runs the full MultiNetworkPolicy test suite in order and prints a final
# summary. Does not run cleanup automatically - run 90-cleanup.sh yourself
# afterward. Set SKIP_INSTALL=1 to skip 00-install-controller.sh if the
# controller is already deployed, and SKIP_TOPOLOGY=1 to skip
# 10-deploy-topology.sh if the topology is already up with a valid
# results/topology.env.
set -uo pipefail
DIR="$(dirname "$0")"

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

[[ "${SKIP_INSTALL:-0}" == "1" ]] || run_stage "00-install-controller.sh"
[[ "${SKIP_TOPOLOGY:-0}" == "1" ]] || run_stage "10-deploy-topology.sh"

run_stage "15-admission-tests.sh"
run_stage "20-ingress-tests.sh"
run_stage "25-egress-tests.sh"
run_stage "30-policytype-and-union-tests.sh"
run_stage "35-lifecycle-tests.sh"
run_stage "40-isolation-tests.sh"
run_stage "45-node-recovery-tests.sh"
run_stage "50-custom-rule-test.sh"

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
echo "Run ${DIR}/90-cleanup.sh when done (add --all to also remove the CRD/controller)."

[[ "${#FAILED_STAGES[@]}" -eq 0 ]]
