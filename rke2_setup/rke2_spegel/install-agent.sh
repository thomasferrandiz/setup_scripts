#!/bin/bash -xv
set -Eeuo pipefail

INSTALL_RKE2_VERSION=v1.30.7+rke2r1
# INSTALL_RKE2_VERSION="latest"
INSTALL_RKE2_TYPE="agent"

RKE2_SERVER="10.11.0.38"

USE_AIRGAP="${USE_AIRGAP:-0}"
OPTIND=1  
while getopts "h?va" opt; do
    case "$opt" in
    h|\?)
        echo "Usage: $0 [-v] [-j] [-a]"
        exit 0
        ;;
    v)  verbose=1
        ;;
    a)  USE_AIRGAP=1
        ;;

    esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift
# uninstall
/opt/rke2/bin/rke2-uninstall.sh || true

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
mkdir -p $(dirname $FILE) 
cat << EOF > config_agent.yaml
server: "https://${RKE2_SERVER}:9345"
token: "secret"
disable-default-registry-endpoint: true
EOF
sudo cp $PWD/config_agent.yaml $FILE

curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=${INSTALL_RKE2_TYPE} INSTALL_RKE2_CHANNEL=${INSTALL_RKE2_VERSION} sh -

sudo systemctl enable rke2-${INSTALL_RKE2_TYPE}.service
sudo systemctl start rke2-${INSTALL_RKE2_TYPE}.service

# journalctl -u rke2-server -f


# configure kubectl
# mkdir -p ~/.kube
# ln -snf /etc/rancher/rke2/rke2.yaml ~/.kube/config
# chmod 600 /root/.kube/config
# ln -snf /var/lib/rancher/rke2/agent/etc/crictl.yaml /etc/crictl.yaml
# alias kubectl="/var/lib/rancher/rke2/bin/kubectl"
# alias k="kubectl"
# alias ks="kubectl -n kube-system"

