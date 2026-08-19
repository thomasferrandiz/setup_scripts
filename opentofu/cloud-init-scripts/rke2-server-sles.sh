#!/bin/bash
zypper --non-interactive refresh
zypper --non-interactive install -y wget

${utils_sh}

retry curl -fsSL --retry 3 --retry-delay 5 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3.sh
bash /tmp/get-helm-3.sh

# count.index == 0 gets server_ip = "" (bootstrap); all others join node 0
cat <<EOF > config.yaml
%{ if server_ip != "" }server: "https://${server_ip}:9345"
%{ endif }write-kubeconfig-mode: 644
token: "${token}"
cluster-cidr: 10.42.0.0/16,2001:cafe:42::/56
service-cidr: 10.43.0.0/16,2001:cafe:43::/112
cni: ${cni}
EOF

mkdir -p /etc/rancher/rke2
cp config.yaml /etc/rancher/rke2/config.yaml

user=$(ls /home/)
mv config.yaml /home/$${user}/config.yaml
chown $${user}:$${user} /home/$${user}/config.yaml
retry curl -fsSL --retry 3 --retry-delay 5 https://get.rke2.io -o /tmp/install-rke2.sh
retry env INSTALL_RKE2_CHANNEL="latest" bash /tmp/install-rke2.sh
systemctl enable --now rke2-server
echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> /home/$${user}/.profile
echo "export PATH=$PATH:/var/lib/rancher/rke2/bin/" >> /home/$${user}/.profile
echo "alias k=kubectl" >> /home/$${user}/.profile

# k9s via tarball (no .deb on SLES)
retry wget -q --tries=5 --retry-connrefused https://github.com/derailed/k9s/releases/download/v0.40.5/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_amd64.tar.gz -C /usr/local/bin k9s
rm k9s_Linux_amd64.tar.gz

# Add the typical manifests
retry wget -q --tries=5 --retry-connrefused https://raw.githubusercontent.com/manuelbuil/PoCs/main/2023/windows-deployment.yml
retry wget -q --tries=5 --retry-connrefused https://raw.githubusercontent.com/manuelbuil/PoCs/main/2021/multitool.yaml
retry wget -q --tries=5 --retry-connrefused https://raw.githubusercontent.com/manuelbuil/PoCs/main/2021/httpbin.yaml
mv windows-deployment.yml multitool.yaml httpbin.yaml /home/$${user}/

# Change the owner of all files
find /home/$${user}/ -type f -exec chown $${user}:$${user} {} \;
