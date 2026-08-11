#!/bin/bash

#RKE2VERSION=v1.28.4+rke2r1
apt update

cat <<EOF > config.yaml
server: "https://${server_ip}:9345"
token: "${token}"
EOF

mkdir -p /etc/rancher/rke2
cp config.yaml /etc/rancher/rke2/config.yaml
user=$(ls /home/)
mv config.yaml /home/$${user}/config.yaml
chown $${user}:$${user} /home/$${user}/config.yaml

curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL="latest" INSTALL_RKE2_TYPE="agent" sh -
systemctl enable --now rke2-agent
