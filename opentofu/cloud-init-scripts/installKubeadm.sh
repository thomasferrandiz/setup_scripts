#!/bin/bash
apt update

# Little server for the other VM to find me
# echo "hola" | nc -l 43210 &

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# cat <<EOF > config.yaml
# write-kubeconfig-mode: 644
# token: "secret"
# cluster-cidr: 10.42.0.0/16,2001:cafe:42::/56
# service-cidr: 10.43.0.0/16,2001:cafe:43::/112
# cni: none
# # curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_CHANNEL="latest" sh -
# EOF

# mkdir -p /etc/rancher/rke2
# cp config.yaml /etc/rancher/rke2/config.yaml

# user=$(ls /home/)
# mv config.yaml /home/${user}/config.yaml
# chown ${user}:${user} /home/${user}/config.yaml
# curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL="latest" sh -
# systemctl enable --now rke2-server

#install docker and containerd
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo gawk -i inplace '!/disabled_plugins/' /etc/containerd/config.toml

sudo systemctl enable --now containerd

# # apt-transport-https may be a dummy package; if so, you can skip that package
# apt-get install -y apt-transport-https ca-certificates curl gpg
# # If the directory `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
# mkdir -p -m 755 /etc/apt/keyrings
# curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# # This overwrites any existing configuration in /etc/apt/sources.list.d/kubernetes.list
# echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# apt-get update
# apt-get install -y kubelet kubeadm kubectl
# apt-mark hold kubelet kubeadm kubectl

# systemctl enable --now kubelet




# echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> /home/${user}/.profile
# echo "export PATH=$PATH:/var/lib/rancher/rke2/bin/" >> /home/${user}/.profile
# echo "alias k=kubectl" >> /home/${user}/.profile

#Add k9s
wget https://github.com/derailed/k9s/releases/download/v0.40.5/k9s_linux_amd64.deb
sudo dpkg -i ./k9s_linux_amd64.deb
rm k9s_linux_amd64.deb

# Add the typical manifests
wget https://raw.githubusercontent.com/manuelbuil/PoCs/main/2023/windows-deployment.yml
wget https://raw.githubusercontent.com/manuelbuil/PoCs/main/2021/multitool.yaml
wget https://raw.githubusercontent.com/manuelbuil/PoCs/main/2021/httpbin.yaml
mv windows-deployment.yml multitool.yaml httpbin.yaml /home/${user}/

# Change the owner of all files
find /home/${user}/ -type f -exec chown ${user}:${user} {} \;


# run manually
# sudo kubeadm init --pod-network-cidr=10.244.0.0/16
