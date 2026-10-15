#!/bin/bash
set -euo pipefail

config_file=/etc/rancher/rke2/config.yaml
node_name=$(hostname --static)

zypper --non-interactive refresh
zypper --non-interactive install -y curl

if [[ "$node_name" == "bench-cp-01" ]]; then
  manifest_dir=/var/lib/rancher/rke2/server/manifests
  mkdir -p "$manifest_dir"
  cat > "$manifest_dir/rke2-cilium-config.yaml" <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    kubeProxyReplacement: true
    k8sServiceHost: localhost
    k8sServicePort: 6443
    ipam:
      mode: kubernetes
    ipv4:
      enabled: true
    ipv6:
      enabled: false
EOF
fi

if grep -q '^server:' "$config_file"; then
  api_endpoint=$(awk '$1 == "server:" { sub("https://", "", $2); sub(":9345$", "", $2); print $2 }' "$config_file")
  endpoint_ready=false

  echo "Waiting for the RKE2 supervisor at ${api_endpoint}:9345"
  attempt=1
  while (( attempt <= 90 )); do
    if curl --silent --output /dev/null --insecure --connect-timeout 3 --max-time 5 \
      "https://${api_endpoint}:9345/"; then
      endpoint_ready=true
      break
    fi
    sleep 10
    attempt=$((attempt + 1))
  done

  if [[ "$endpoint_ready" != true ]]; then
    echo "Timed out waiting for ${api_endpoint}:9345" >&2
    exit 1
  fi
fi

curl -fsSL --retry 3 --retry-delay 5 https://get.rke2.io -o /tmp/install-rke2.sh
env INSTALL_RKE2_CHANNEL=stable bash /tmp/install-rke2.sh
systemctl enable --now rke2-server
