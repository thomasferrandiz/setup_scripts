#!/bin/bash
set +x
set -e -o pipefail

# use GNU sed on macos (brew install gsed)
SED=gsed

# Directory of the base (variable-driven) AWS config and its variants.
AWS_DIR="aws"
AWS_DEMO_DIR="aws/demo"
AWS_CNI_DIR="aws/cni-test"

RKECLUSTERFILE="/home/tferrandiz/rke-cluster1/cluster.yml"
RKECLUSTERSTATEFILE="/home/tferrandiz/rke-cluster1/cluster.rkestate"

# changeSshConfig adds the publicIP of the new VMs to ~/.ssh/config.
# Must be called from inside the tofu config directory.
changeSshConfig () {
case $1 in
  "azure")
    case $2 in
      "HA")
        ip0=$(tofu output -json | jq '.ipAddresses.value[0]')
        ip1=$(tofu output -json | jq '.ipAddresses.value[1]')
        ip2=$(tofu output -json | jq '.ipAddresses.value[2]')
        ip3=$(tofu output -json | jq '.ipAddresses.value[3]')
        ip4=$(tofu output -json | jq '.ipAddresses.value[4]')
        echo $ip0
        echo $ip1
        echo $ip2
        echo $ip3
        echo $ip4
        ${SED} -i '/^Host azure-ubuntu/{n;s/Hostname .*/Hostname '$ip0'/}' ~/.ssh/config
        ${SED} -i '/^Host azure-ubuntu2/{n;s/Hostname .*/Hostname '$ip1'/}' ~/.ssh/config
        ${SED} -i '/^Host azure-ubuntu3/{n;s/Hostname .*/Hostname '$ip2'/}' ~/.ssh/config
        ${SED} -i '/^Host azure-ubuntu4/{n;s/Hostname .*/Hostname '$ip3'/}' ~/.ssh/config
        ${SED} -i '/^Host azure-ubuntu5/{n;s/Hostname .*/Hostname '$ip4'/}' ~/.ssh/config
      ;;
      *)
        ip0=$(tofu output -json | jq '.ipAddresses.value[0]')
        ip1=$(tofu output -json | jq '.ipAddresses.value[1]')
        ip2=$(tofu output -json | jq '.ipAddresses.value[2]')
        ${SED} -i '/^Host azure-ubuntu/{n;s/Hostname .*/Hostname '$ip0'/}' ~/.ssh/config
        ${SED} -i '/^Host azure-ubuntu2/{n;s/Hostname .*/Hostname '$ip1'/}' ~/.ssh/config
        ${SED} -i '/^Host azure-ubuntu3/{n;s/Hostname .*/Hostname '$ip2'/}' ~/.ssh/config
        ${SED} -i '/^Host azure-windows/{n;s/Hostname .*/Hostname '$ip2'/}' ~/.ssh/config
    esac
  ;;
  "aws")
    case $2 in
      "cni-test")
        ipv4CP=$(tofu output -json | jq '.publicIP_CP.value[0]')
        ipv4DP_0=$(tofu output -json | jq '.publicIP_DP0.value')
        ipv4DP_1=$(tofu output -json | jq '.publicIP_DP1.value')
        ${SED} -i '/^Host aws-cni-cp/{n;s/HostName .*/HostName '$ipv4CP'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-cni-dp0/{n;s/HostName .*/HostName '$ipv4DP_0'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-cni-dp1/{n;s/HostName .*/HostName '$ipv4DP_1'/}' ~/.ssh/config
      ;;
      *)
        ipv6=$(tofu output -json | jq '.ipv6IP.value[0]')
        ipv4jump=$(tofu output -json | jq '.publicIP.value')
        ipv4public1=$(tofu output -json | jq '.publicIP.value[0]')
        ipv4public2=$(tofu output -json | jq '.publicIP.value[1]')
        ipv4public3=$(tofu output -json | jq '.publicIP.value[2]')
        ipv4public4=$(tofu output -json | jq '.publicIP.value[3]')
        ipv4public5=$(tofu output -json | jq '.publicIP.value[4]')
        ${SED} -i '/^Host aws-ubuntu/{n;s/HostName .*/HostName '$ipv4public1'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-ubuntu2/{n;s/HostName .*/HostName '$ipv4public2'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-ubuntu3/{n;s/HostName .*/HostName '$ipv4public3'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-ubuntu4/{n;s/HostName .*/HostName '$ipv4public4'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-ubuntu5/{n;s/HostName .*/HostName '$ipv4public5'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-suse/{n;s/HostName .*/HostName '$ipv4public1'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-suse2/{n;s/HostName .*/HostName '$ipv4public2'/}' ~/.ssh/config
        ${SED} -i '/^Host aws-suse3/{n;s/HostName .*/HostName '$ipv4public3'/}' ~/.ssh/config
    esac
    ;;
  *)
    echo "Something went wrong in the ssh"
    exit 1
esac
}

# updaterke1cluster updates the addresses of the rke1 cluster
updaterke1cluster() {
  pushd $1
  ipPublic0=$(tofu output -json | jq '.ipAddresses.value[0]')
  ipPublic1=$(tofu output -json | jq '.ipAddresses.value[1]')
  ipPrivate0=$(tofu output -json | jq '.ipPrivateAddresses.value[0]')
  ipPrivate1=$(tofu output -json | jq '.ipPrivateAddresses.value[1]')
  ${SED} -i '4s/.*/- address: '${ipPublic0}'/' ${RKECLUSTERFILE}
  ${SED} -i '5s/.*/  internal_address: '${ipPrivate0}'/' ${RKECLUSTERFILE}
  ${SED} -i '12s/.*/- address: '${ipPublic1}'/' ${RKECLUSTERFILE}
  ${SED} -i '13s/.*/  internal_address: '${ipPrivate1}'/' ${RKECLUSTERFILE}
  rm ${RKECLUSTERSTATEFILE}
  popd
}

# hclList builds an HCL list literal from its arguments, e.g.
#   hclList a.sh b.sh  ->  ["a.sh","b.sh"]
hclList() {
  local out="["
  local first=1
  for f in "$@"; do
    if [ $first -eq 1 ]; then first=0; else out="${out},"; fi
    out="${out}\"${f}\""
  done
  echo "${out}]"
}

# applyTofu runs tofu apply and refresh to get the publicIP of the new VMs.
# Usage: applyTofu <config-dir> <ssh-flavor> [extra tofu -var args...]
applyTofu () {
  local dir=$1
  local sshFlavor=$2
  shift 2
  pushd "$dir" >/dev/null
  tofu init -input=false -upgrade >/dev/null
  tofu apply --auto-approve "$@"
  sleep 10
  tofu apply -refresh-only --auto-approve "$@"
  sleep 5
  changeSshConfig aws "$sshFlavor"
  popd >/dev/null
}

planTofu() {
  pushd "$1" >/dev/null
  shift
  tofu init -input=false -upgrade >/dev/null
  tofu plan "$@"
  popd >/dev/null
}

# copyManifests scps the aws/manifests directory to each given ssh host,
# waiting for its ssh daemon to come up first (VMs may still be booting).
copyManifests() {
  local manifestsDir="${AWS_DIR}/manifests"
  for host in "$@"; do
    echo "Copying manifests to ${host}..."
    until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "${host}" true 2>/dev/null; do
      sleep 5
    done
    scp -r -o StrictHostKeyChecking=no "${manifestsDir}" "${host}:"
  done
}

case $1 in
  "rancher-aws")
    echo "rancher-aws option"
    files=$(hclList \
      "../cloud-init-scripts/installK3sAndRancher_0.sh" \
      "../cloud-init-scripts/installK3sAndRancher_1.sh")
    applyTofu "${AWS_DIR}" "" -var="cloud_init_files=${files}"
    echo "Access <public-ip>.sslip.io in your browser (see 'tofu output publicIP')"
  ;;
  "rancher-prime-aws")
    echo "rancher prime option"
    files=$(hclList \
      "../cloud-init-scripts/installK3sAndRancherPrime_0.sh" \
      "../cloud-init-scripts/installK3sAndRancherPrime_1.sh")
    applyTofu "${AWS_DIR}" "" -var="cloud_init_files=${files}"
    echo "Access <public-ip>.sslip.io in your browser (see 'tofu output publicIP')"
  ;;
  "k3s-aws")
    echo "k3s option"
    files=$(hclList \
      "../cloud-init-scripts/k3s-server.sh" \
      "../cloud-init-scripts/k3s-agent.sh" \
      "../cloud-init-scripts/k3s-agent.sh")
    applyTofu "${AWS_DIR}" "" -var="cloud_init_files=${files}"
  ;;
  "kubeadm")
    echo "kubeadm option"
    files=$(hclList \
      "../cloud-init-scripts/installKubeadm.sh" \
      "../cloud-init-scripts/installKubeadm.sh")
    applyTofu "${AWS_DIR}" "" -var="cloud_init_files=${files}"
  ;;
  "rke2")
    echo "rke2 option with cni plugin $2"
    case $2 in
      ""|"canal")
        echo "CNI plugin is canal"
        cniPlugin=canal
      ;;
      "calico")
        echo "CNI plugin is calico"
        cniPlugin=calico
      ;;
      "cilium")
        echo "CNI plugin is cilium"
        cniPlugin=cilium
      ;;
      "flannel")
        echo "CNI plugin is flannel"
        cniPlugin=flannel
      ;;
      "none")
        echo "CNI plugin is none"
        cniPlugin=none
      ;;
      *)
        echo "$2 is not a valid CNI plugin"
        exit 1
      ;;
    esac
    if [ "$3" == "multus" ]; then
      echo "Multus included!"
      cniPlugin="$3,${cniPlugin}"
    fi
    files=$(hclList \
      "../cloud-init-scripts/rke2-server.sh" \
      "../cloud-init-scripts/rke2-agent.sh")
    applyTofu "${AWS_DIR}" "" -var="cloud_init_files=${files}" -var="cni=${cniPlugin}"
    copyManifests aws-ubuntu aws-ubuntu2
  ;;
  "rke2-ha")
    echo "rke2 in HA mode"
    files=$(hclList \
      "../cloud-init-scripts/rke2-server.sh" \
      "../cloud-init-scripts/rke2-server.sh" \
      "../cloud-init-scripts/rke2-server.sh" \
      "../cloud-init-scripts/rke2-agent.sh" \
      "../cloud-init-scripts/rke2-agent.sh")
    applyTofu "${AWS_DIR}" "HA" -var="cloud_init_files=${files}"
  ;;
  "demo-gpu")
    echo "demo-gpu"
    applyTofu "${AWS_DEMO_DIR}" ""
  ;;
  "test-cni")
    echo "test-cni"
    files=$(hclList \
      "../../cloud-init-scripts/cni-test/installRKE2_DP_0.sh" \
      "../../cloud-init-scripts/cni-test/installRKE2_DP_1.sh")
    applyTofu "${AWS_CNI_DIR}" "cni-test" -var="cloud_init_files=${files}"
  ;;
  "rke2-sles")
    echo "rke2-sles option with cni plugin $2"
    case $2 in
      ""|"canal")
        echo "CNI plugin is canal"
        cniPlugin=canal
      ;;
      "calico")
        echo "CNI plugin is calico"
        cniPlugin=calico
      ;;
      "cilium")
        echo "CNI plugin is cilium"
        cniPlugin=cilium
      ;;
      "flannel")
        echo "CNI plugin is flannel"
        cniPlugin=flannel
      ;;
      "none")
        echo "CNI plugin is none"
        cniPlugin=none
      ;;
      *)
        echo "$2 is not a valid CNI plugin"
        exit 1
      ;;
    esac
    if [ "$3" == "multus" ]; then
      echo "Multus included!"
      cniPlugin="$3,${cniPlugin}"
    fi
    files=$(hclList \
      "../cloud-init-scripts/rke2-server-sles.sh" \
      "../cloud-init-scripts/rke2-agent-sles.sh")
    applyTofu "${AWS_DIR}" "" -var="cloud_init_files=${files}" -var="cni=${cniPlugin}" -var="os=sles16"
  ;;
  "rke2-ha-sles")
    echo "rke2-ha-sles in HA mode"
    files=$(hclList \
      "../cloud-init-scripts/rke2-server-sles.sh" \
      "../cloud-init-scripts/rke2-server-sles.sh" \
      "../cloud-init-scripts/rke2-server-sles.sh" \
      "../cloud-init-scripts/rke2-agent-sles.sh" \
      "../cloud-init-scripts/rke2-agent-sles.sh")
    applyTofu "${AWS_DIR}" "HA" -var="cloud_init_files=${files}" -var="os=sles16"
  ;;
  "k3s-sles")
    echo "k3s-sles option"
    files=$(hclList \
      "../cloud-init-scripts/k3s-server-sles.sh" \
      "../cloud-init-scripts/k3s-agent-sles.sh" \
      "../cloud-init-scripts/k3s-agent-sles.sh")
    applyTofu "${AWS_DIR}" "" -var="cloud_init_files=${files}" -var="os=sles16"
  ;;
  *)
    echo "$0 executed without a valid arg."
    echo "Usage: $0 <flavor> [cni] [multus]"
    echo "Flavors: k3s-aws, rancher-aws, rancher-prime-aws, kubeadm, rke2, rke2-ha, demo-gpu, test-cni"
    echo "        rke2-sles, rke2-ha-sles, k3s-sles"
    exit 1
esac
