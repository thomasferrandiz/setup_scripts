#!/bin/bash -xv
set -Eeuo pipefail

INSTALL_RKE2_VERSION=v1.31.7+rke2r1
#INSTALL_RKE2_VERSION=v1.29.0-rc1+rke2r1
# INSTALL_RKE2_VERSION="latest"
INSTALL_RKE2_TYPE="server"

# uninstall
/opt/rke2/bin/rke2-uninstall.sh || true

FILE="/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml"
mkdir -p $(dirname $FILE)
cat << EOF > $FILE 
# $FILE
---
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    cni:
      exclusive: false
    kubeProxyReplacement: true
    k8sServiceHost: 10.124.138.101
    k8sServicePort: 6443
    bpf:
      masquerade: true
    ipam:
      mode: kubernetes
    cni:
      exclusive: false
    l2announcements:
      enabled: true
    externalIPs:
      enabled: true
    socketLB: 
      hostNamespaceOnly: true
    ingressController:
      enabled: true
    gatewayAPI:
      enabled: false
EOF

FILE="/var/lib/rancher/rke2/server/manifests/rke2-multus-config.yaml"
mkdir -p $(dirname $FILE)
cat << EOF > $FILE
# $FILE
---
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-multus
  namespace: kube-system
spec:
  valuesContent: |-
    rke2-whereabouts:
      enabled: true
EOF

FILE="/etc/rancher/rke2/config.yaml"
mkdir -p $(dirname $FILE) 
cat << EOF > $FILE 
write-kubeconfig-mode: 644
token: "secret"
disable-kube-proxy: "true"
cni:
  - multus
  - cilium
# test
cluster-cidr: 10.244.0.0/16
service-cidr: 10.96.0.0/12
disable:
  - disable-cloud-controller
  - rke2-snapshot-controller
  - rke2-snapshot-controller-crd
  - rke2-snapshot-validation-webhook
  - rke2-ingress-nginx
EOF

curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=${INSTALL_RKE2_TYPE} INSTALL_RKE2_CHANNEL=${INSTALL_RKE2_VERSION} sh -

systemctl enable rke2-${INSTALL_RKE2_TYPE}.service
systemctl start rke2-${INSTALL_RKE2_TYPE}.service

# journalctl -u rke2-server -f


# configure kubectl
mkdir -p ~/.kube
ln -snf /etc/rancher/rke2/rke2.yaml ~/.kube/config
chmod 600 /root/.kube/config
ln -snf /var/lib/rancher/rke2/agent/etc/crictl.yaml /etc/crictl.yaml
alias kubectl="/var/lib/rancher/rke2/bin/kubectl"
alias k="kubectl"
alias ks="kubectl -n kube-system"
