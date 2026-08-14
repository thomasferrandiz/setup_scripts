#!/bin/bash
zypper --non-interactive refresh

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

cat <<EOF > config.yaml
server: "https://${server_ip}:6443"
token: "${token}"
EOF

mkdir -p /etc/rancher/k3s
cp config.yaml /etc/rancher/k3s/config.yaml
user=$(ls /home/)
mv config.yaml /home/$${user}/config.yaml
chown $${user}:$${user} /home/$${user}/config.yaml

curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="latest" K3S_URL=https://${server_ip}:6443 K3S_TOKEN=${token} sh -
