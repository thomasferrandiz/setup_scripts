#!/bin/sh
set +x
set -e -o pipefail

#use GNU sed on macos (brew install gsed)
SED=gsed

RKECLUSTERFILE="/home/tferrandiz/rke-cluster1/cluster.yml"
RKECLUSTERSTATEFILE="/home/tferrandiz/rke-cluster1/cluster.rkestate"

# changeSshConfig adds the publicIP of the new VMs to ~/.ssh/config
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

# applyTofu runs tofu apply and refresh to get the publicIP of the new VMs
applyTofu () {
  pushd $1
  # tofu init
  tofu apply --auto-approve
  sleep 10
  tofu refresh
  sleep 5
  changeSshConfig $1 $2
  popd
}

planTofu() {
  pushd $1
  tofu plan
  popd
}

case $1 in
  "rke1")
    echo "rke1 option"
    cp azure/template/azure.tf.template azure/azure.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installDockerHelm.sh"/g' azure/azure.tf
    ${SED} -i 's/%COUNT%/2/g' azure/azure.tf
    applyTofu azure
    updaterke1cluster azure
  ;;
  "rancher")
    echo "rancher option"
    cp azure/template/azure.tf.template azure/azure.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installK3sAndRancher_${count.index}.sh"/g' azure/azure.tf
    ${SED} -i 's/%COUNT%/2/g' azure/azure.tf
    applyTofu azure
    echo "Access ${ip0//\"/}.sslip.io in your browser"
  ;;
  "rancher-aws")
    echo "rancher-aws option"
    cp aws/template/aws.tf.template aws/aws.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installK3sAndRancher_${count.index}.sh"/g' aws/aws.tf
    ${SED} -i 's/%COUNT%/2/g' aws/aws.tf
    applyTofu aws
    echo "Access ${ipv4public1//\"/}.sslip.io in your browser"
  ;;
  "rancher-prime")
    echo "rancher prime option"
    cp azure/template/azure.tf.template azure/azure.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installK3sAndRancherPrime_${count.index}.sh"/g' azure/azure.tf
    ${SED} -i 's/%COUNT%/2/g' azure/azure.tf
    applyTofu azure
    echo "Access ${ip0//\"/}.sslip.io in your browser"
  ;;
  "rancher-prime-aws")
    echo "rancher prime option"
    cp aws/template/aws.tf.template aws/aws.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installK3sAndRancherPrime_${count.index}.sh"/g' aws/aws.tf
    ${SED} -i 's/%COUNT%/2/g' aws/aws.tf
    applyTofu aws
    echo "Access ${ipv4public1//\"/}.sslip.io in your browser"
  ;;
  "k3s")
    echo "k3s option"
    cp azure/template/azure.tf.template azure/azure.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installK3s_${count.index}.sh"/g' azure/azure.tf
    ${SED} -i 's/%COUNT%/3/g' azure/azure.tf
    applyTofu azure
  ;;
  "k3s-aws")
    echo "k3s option"
    cp aws/template/aws.tf.template aws/aws.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installK3s_${count.index}.sh"/g' aws/aws.tf
    ${SED} -i 's/%COUNT%/3/g' aws/aws.tf
    applyTofu aws
  ;;
  "k3s-ipv6")
    echo "k3s-ipv6 option"
    cp aws/template/aws.tf.template aws/aws.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installK3snoDS.sh"/g' aws/aws.tf
    applyTofu aws
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
    if [ "$3" == "multus" ];then
	    echo "Multus included!"
	    cniPlugin="$3,${cniPlugin}"
    fi
    ${SED} -i "s/cni: .*/cni: ${cniPlugin}/g" cloud-init-scripts\/installRKE2_0.sh
    cp aws/template/aws.tf.template aws/aws.tf
    ${SED} -i 's#%CLOUDINIT%#"../cloud-init-scripts/installRKE2_${count.index}.sh"#g' aws/aws.tf
    ${SED} -i 's/%COUNT%/2/g' aws/aws.tf
    applyTofu aws
  ;;
  "windows")
    echo "rke2 and windows with cni plugin $2"
    case $2 in
      ""|"calico")
        echo "CNI plugin is calico"
        cniPlugin=calico
      ;;
      "none")
        echo "CNI plugin is flannel"
        cniPlugin=flannel
      ;;
      *)
        echo "$2 is not a valid CNI plugin"
        exit 1
      ;;
    esac
    cp azure/template/azure.tf.windows.template azure/azure.tf
    ${SED} -i "s/cni: .*/cni: ${cniPlugin}/g" cloud-init-scripts\/installRKE2NoDS_0.sh
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installRKE2NoDS_${count.index}.sh"/g' azure/azure.tf
    applyTofu azure
    echo "ssh azure-windows 'powershell.exe -File C:\AzureData\install.ps1 MYIP'"
    echo "ssh azure-windows 'powershell.exe C:\usr\local\bin\rke2.exe agent service --add'"
    echo "ssh azure-windows 'powershell.exe Start-Service -Name rke2'"
  ;;
  "rke2-ha")
    echo "rke2 in HA mode"
    cp aws/template/aws.tf.template aws/aws.tf
    ${SED} -i 's/%CLOUDINIT%/"..\/cloud-init-scripts\/installRKE2HA_${count.index}.sh"/g' aws/aws.tf
    ${SED} -i 's/%COUNT%/5/g' aws/aws.tf
    applyTofu aws HA
  ;;
  "demo-gpu")
    echo "demo-gpu"
    cp aws/template/aws-demo.tf.template aws/aws.tf
    applyTofu aws
  ;;
  "test-cni")
    echo "test-cni"
    cp aws/template/aws-cni.tf.template aws/aws.tf
    ${SED} -i 's#%CLOUDINIT%#"../cloud-init-scripts/cni-test/installRKE2_DP_${count.index}.sh"#g' aws/aws.tf
    applyTofu aws cni-test
  ;;
  *)
    echo "$0 executed without arg. Please use rke1, rancher, rancher-prime, k3s, k3s-ipv6, rke2 or windows"
    exit 1
esac
