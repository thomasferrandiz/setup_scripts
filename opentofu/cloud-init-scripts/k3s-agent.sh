#!/bin/bash
apt update

${utils_sh}

retry curl -fsSL --retry 3 --retry-delay 5 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3.sh
bash /tmp/get-helm-3.sh

cat <<EOF > config.yaml
server: "https://${server_ip}:6443"
token: "${token}"
EOF

mkdir -p /etc/rancher/k3s
cp config.yaml /etc/rancher/k3s/config.yaml
user=$(ls /home/)
mv config.yaml /home/$${user}/config.yaml
chown $${user}:$${user} /home/$${user}/config.yaml

retry curl -fsSL --retry 3 --retry-delay 5 https://get.k3s.io -o /tmp/install-k3s.sh
retry env INSTALL_K3S_CHANNEL="latest" K3S_URL=https://${server_ip}:6443 K3S_TOKEN=${token} bash /tmp/install-k3s.sh
