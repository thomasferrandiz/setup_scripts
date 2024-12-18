#!/bin/bash -xv
set -Eeuo pipefail

USE_AIRGAP=1

INSTALL_RKE2_VERSION=v1.30.7+rke2r1
# INSTALL_RKE2_VERSION="latest"
INSTALL_RKE2_TYPE="server"

JOIN="${JOIN:-0}"

OPTIND=1  
while getopts "h?vja" opt; do
    case "$opt" in
    h|\?)
        echo "Usage: $0 [-v] [-j] [-a]"
        exit 0
        ;;
    v)  verbose=1
        ;;
    j)  JOIN=$OPTARG
        ;;
    a)  USE_AIRGAP=$OPTARG
        ;;

    esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift

# uninstall
/usr/local/bin/rke2/bin/rke2-uninstall.sh || true

#airgap install
if [[ $USE_AIRGAP != 0 ]]; then
    IMAGES_DIR=/var/lib/rancher/rke2/agent/images/
    sudo mkdir -p ${IMAGES_DIR}
    wget https://github.com/rancher/rke2/releases/download/${INSTALL_RKE2_VERSION}/rke2-images.linux-amd64.tar.gz
    sudo mv ./rke2-images.linux-amd64.tar.gz ${IMAGES_DIR}
fi

FILE="/etc/rancher/rke2/registries.yaml"
sudo mkdir -p $(dirname $FILE) 
sudo cp $PWD/registries.yaml $FILE

FILE="/etc/rancher/rke2/config.yaml"
sudo mkdir -p $(dirname $FILE) 
if [[ $JOIN == 0]]; then
    sudo cp $PWD/config_server.yaml $FILE
else
    sudo cp $PWD/config_server_secondary.yaml $FILE
fi

curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=${INSTALL_RKE2_TYPE} INSTALL_RKE2_CHANNEL=${INSTALL_RKE2_VERSION} sudo sh -

sudo systemctl enable rke2-${INSTALL_RKE2_TYPE}.service
sudo systemctl start rke2-${INSTALL_RKE2_TYPE}.service

# journalctl -u rke2-server -f


# configure kubectl
# sudo mkdir -p ~/.kube
# ln -snf /etc/rancher/rke2/rke2.yaml ~/.kube/config
# chmod 600 /root/.kube/config
# ln -snf /var/lib/rancher/rke2/agent/etc/crictl.yaml /etc/crictl.yaml
# alias kubectl="/var/lib/rancher/rke2/bin/kubectl"
# alias k="kubectl"
# alias ks="kubectl -n kube-system"
