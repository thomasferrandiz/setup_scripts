#!/bin/bash -xv
set -Eeuo pipefail

INSTALL_RKE2_VERSION=v1.30.7+rke2r1
# INSTALL_RKE2_VERSION="latest"
INSTALL_RKE2_TYPE="agent"

RKE2_SERVER="10.11.0.38"

# uninstall
/opt/rke2/bin/rke2-uninstall.sh || true

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

curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=${INSTALL_RKE2_TYPE} INSTALL_RKE2_CHANNEL=${INSTALL_RKE2_VERSION} sh -

systemctl enable rke2-${INSTALL_RKE2_TYPE}.service
systemctl start rke2-${INSTALL_RKE2_TYPE}.service

# journalctl -u rke2-server -f


# configure kubectl
# mkdir -p ~/.kube
# ln -snf /etc/rancher/rke2/rke2.yaml ~/.kube/config
# chmod 600 /root/.kube/config
# ln -snf /var/lib/rancher/rke2/agent/etc/crictl.yaml /etc/crictl.yaml
# alias kubectl="/var/lib/rancher/rke2/bin/kubectl"
# alias k="kubectl"
# alias ks="kubectl -n kube-system"

