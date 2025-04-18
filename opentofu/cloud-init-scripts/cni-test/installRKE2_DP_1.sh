#!/bin/bash

apt update

wget https://raw.githubusercontent.com/manuelbuil/PoCs/refs/heads/main/2022/terraform/cloud-init-scripts/utils.sh -O /tmp/utils.sh

source /tmp/utils.sh

# The other created VM has the next or the previous IP. Ping to check which one is it
myIP=$(ip addr show $(ip route | awk '/default/ { print $5; exit }') | grep "inet" | head -n 1 | awk '/inet/ {print $2}' | cut -d'/' -f1)
echo This my myIP: ${myIP}

# Second interface for use with multus
cat <<EOF > /etc/netplan/51-multus.yaml
network:
  version: 2
  ethernets:
    ens6:
      dhcp4: true
EOF
netplan apply

result=$(getServerIP ${myIP})

cat <<EOF > config.yaml
server: "https://${result}:9345"
token: "secret"
# curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_CHANNEL="latest" INSTALL_RKE2_TYPE="agent" sh -
EOF

mkdir -p /etc/rancher/rke2
cp config.yaml /etc/rancher/rke2/config.yaml
user=$(ls /home/)
mv config.yaml /home/${user}/config.yaml
chown ${user}:${user} /home/${user}/config.yaml

curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL="latest" INSTALL_RKE2_TYPE="agent" sh -
systemctl enable --now rke2-agent

sudo DEBIAN_FRONTEND=noninteractive  apt install -y iperf3
sudo systemctl disable iperf3 --now
sudo systemctl stop iperf3
sudo killall iperf3
