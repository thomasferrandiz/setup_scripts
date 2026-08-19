#!/bin/bash
zypper --non-interactive refresh

${utils_sh}

cat <<EOF > config.yaml
server: "https://${server_ip}:9345"
token: "${token}"
EOF

mkdir -p /etc/rancher/rke2
cp config.yaml /etc/rancher/rke2/config.yaml
user=$(ls /home/)
mv config.yaml /home/$${user}/config.yaml
chown $${user}:$${user} /home/$${user}/config.yaml

retry curl -fsSL --retry 3 --retry-delay 5 https://get.rke2.io -o /tmp/install-rke2.sh
retry env INSTALL_RKE2_CHANNEL="latest" INSTALL_RKE2_TYPE="agent" bash /tmp/install-rke2.sh
systemctl enable --now rke2-agent
