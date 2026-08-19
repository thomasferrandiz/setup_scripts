#!/bin/bash
apt update

${utils_sh}

retry curl -fsSL --retry 3 --retry-delay 5 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3.sh
bash /tmp/get-helm-3.sh

cat <<EOF > config.yaml
write-kubeconfig-mode: 644
token: "${token}"
# cluster-cidr: 10.42.0.0/16,2001:cafe:42::/56
# service-cidr: 10.43.0.0/16,2001:cafe:43::/112
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16
# kube-proxy-arg:
#   - proxy-mode=nftables
flannel-backend: none
EOF

mkdir -p /etc/rancher/k3s
cp config.yaml /etc/rancher/k3s/config.yaml

user=$(ls /home/)
mv config.yaml /home/$${user}/config.yaml
chown $${user}:$${user} /home/$${user}/config.yaml
retry curl -fsSL --retry 3 --retry-delay 5 https://get.k3s.io -o /tmp/install-k3s.sh
retry env INSTALL_K3S_CHANNEL="latest" bash /tmp/install-k3s.sh

echo "alias k=kubectl" >> /home/$${user}/.profile

#Add k9s
retry wget -q --tries=5 --retry-connrefused https://github.com/derailed/k9s/releases/download/v0.40.5/k9s_linux_amd64.deb
sudo dpkg -i ./k9s_linux_amd64.deb
rm k9s_linux_amd64.deb

# Add the typical manifests
retry wget -q --tries=5 --retry-connrefused https://raw.githubusercontent.com/manuelbuil/PoCs/main/2023/windows-deployment.yml
retry wget -q --tries=5 --retry-connrefused https://raw.githubusercontent.com/manuelbuil/PoCs/main/2021/multitool.yaml
retry wget -q --tries=5 --retry-connrefused https://raw.githubusercontent.com/manuelbuil/PoCs/main/2021/httpbin.yaml
mv windows-deployment.yml multitool.yaml httpbin.yaml /home/$${user}/

# Change the owner of all files
find /home/$${user}/ -type f -exec chown $${user}:$${user} {} \;
