#!/bin/bash
set +x
set -e -o pipefail

AWS_DIR="aws"
AWS_DEMO_DIR="aws/demo"
AWS_CNI_DIR="aws/cni-test"

# destroyTofu runs tofu destroy for a config dir with n dummy placeholder files.
# Usage: destroyTofu <config-dir> [n]
destroyTofu() {
  local dir=$1
  local n=${2:-0}
  pushd "$dir" >/dev/null
  tofu init -input=false -upgrade >/dev/null
  if [ "$n" -gt 0 ]; then
    local dummies
    dummies=$(python3 -c "import sys; n=int(sys.argv[1]); print('[' + ','.join(['\"x\"']*n) + ']')" "$n")
    tofu destroy --auto-approve -var="cloud_init_files=${dummies}"
  else
    tofu destroy --auto-approve
  fi
  popd >/dev/null
}

case $1 in
  "rancher-aws"|"rancher-prime-aws"|"kubeadm"|"rke2")
    destroyTofu "${AWS_DIR}" 2
  ;;
  "k3s-aws")
    destroyTofu "${AWS_DIR}" 3
  ;;
  "rke2-ha")
    destroyTofu "${AWS_DIR}" 5
  ;;
  "demo-gpu")
    destroyTofu "${AWS_DEMO_DIR}"
  ;;
  "test-cni")
    destroyTofu "${AWS_CNI_DIR}" 2
  ;;
  *)
    echo "$0 executed without a valid arg."
    echo "Usage: $0 <flavor>"
    echo "Flavors: k3s-aws, rancher-aws, rancher-prime-aws, kubeadm, rke2, rke2-ha, demo-gpu, test-cni"
    exit 1
esac
