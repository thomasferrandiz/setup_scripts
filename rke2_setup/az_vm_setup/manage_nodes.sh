#!/bin/bash

set -euo pipefail

create=unset
delete=unset

RESOURCE_GROUP="rke2-k3s-networking"
VM_IMAGE="SUSE:sles-15-sp6:gen2:2024.08.08"
VM_SIZE="Standard_D2s_v3"
SSH_KEY_NAME="tf-server_key"

SERVER_VM="tf-rke2-server"
AGENT_VM="tf-rke2-agent"

usage(){
>&2 cat << EOF
Usage: $0
   [ -c | --create ] 
   [ -d | --delete ]
EOF
exit 1
}
# --ssh-key-values "/Users/tferrandiz/.ssh/tf-server_key.pub" \

create_vm(){
    name=$1
    echo "Creating VM ${name}..."
    #create VMs
    az vm create --resource-group ${RESOURCE_GROUP} \
        --name ${name} \
        --image ${VM_IMAGE} \
        --public-ip-address-dns-name ${name} \
        --size ${VM_SIZE} \
        --generate-ssh-keys \
        --no-wait

    # az vm auto-shutdown -g ${RESOURCE_GROUP} -n ${name} --time 2000
}

delete_vm(){
  name=$1
  echo "Deleting VM ${name}..."
    az vm delete --resource-group ${RESOURCE_GROUP} \
        --name ${name} --yes
}

args=$(getopt hcd $*)
if [[ $? -gt 0 ]]; then
  usage
fi

set -- $args
while :
do
  case $1 in
    -h)    usage      ; shift   ;;
    -c)   create=1   ; shift ;;
    -d)   delete=1   ; shift ;;
    # -- means the end of the arguments; drop this, and break out of the while loop
    --) shift; break ;;
    *) >&2 echo Unsupported option: $1
       usage ;;
  esac
done

if [[ $create == 1 ]]; then
    create_vm "${SERVER_VM}"
    create_vm "${AGENT_VM}"
fi

if [[ $delete == 1 ]]; then
    delete_vm "${AGENT_VM}"
    delete_vm "${SERVER_VM}"
fi
