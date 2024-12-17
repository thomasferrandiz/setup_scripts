#!/bin/bash -xv
set -Eeuo pipefail

#INSTALL_RKE2_VERSION=v1.28.4+rke2r1
#INSTALL_RKE2_VERSION=v1.29.0-rc1+rke2r1
INSTALL_RKE2_VERSION="latest"
INSTALL_RKE2_TYPE="server"

# uninstall
/usr/local/bin/rke2/bin/rke2-uninstall.sh || true

FILE="/etc/rancher/rke2/registries.yaml"
sudo mkdir -p $(dirname $FILE) 
sudo cat << EOF > $FILE 
mirrors:
  docker.io:
  registry.k8s.io:
EOF

FILE="/etc/rancher/rke2/config.yaml"
sudo mkdir -p $(dirname $FILE) 
sudo cat << EOF > $FILE 
write-kubeconfig-mode: 644
token: "secret"
embedded-registry: true
EOF

curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=${INSTALL_RKE2_TYPE} INSTALL_RKE2_CHANNEL=${INSTALL_RKE2_VERSION} sudo sh -

sudo systemctl enable rke2-${INSTALL_RKE2_TYPE}.service
sudo systemctl start rke2-${INSTALL_RKE2_TYPE}.service

# journalctl -u rke2-server -f


# configure kubectl
sudo mkdir -p ~/.kube
ln -snf /etc/rancher/rke2/rke2.yaml ~/.kube/config
chmod 600 /root/.kube/config
ln -snf /var/lib/rancher/rke2/agent/etc/crictl.yaml /etc/crictl.yaml
alias kubectl="/var/lib/rancher/rke2/bin/kubectl"
alias k="kubectl"
alias ks="kubectl -n kube-system"
