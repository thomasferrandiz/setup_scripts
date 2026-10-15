#!/bin/bash
set -euo pipefail

config_file=/etc/rancher/rke2/config.yaml
rke2_version=$1

# The config is written by yamlencode, which quotes keys and values.
server_endpoint=$(awk '{ gsub(/"/, "") } $1 == "server:" { sub("https://", "", $2); sub(":9345$", "", $2); print $2 }' "$config_file")
if [[ -z "$server_endpoint" ]]; then
  echo "No server address found in ${config_file}" >&2
  exit 1
fi

echo "Waiting for the RKE2 supervisor at ${server_endpoint}:9345"
attempt=1
until curl --silent --output /dev/null --insecure --connect-timeout 3 --max-time 5 \
  "https://${server_endpoint}:9345/"; do
  if (( attempt >= 90 )); then
    echo "Timed out waiting for ${server_endpoint}:9345" >&2
    exit 1
  fi
  sleep 10
  attempt=$((attempt + 1))
done

curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused https://get.rke2.io -o /tmp/install-rke2.sh
env INSTALL_RKE2_TYPE=agent INSTALL_RKE2_VERSION="$rke2_version" bash /tmp/install-rke2.sh
rm /tmp/install-rke2.sh
systemctl enable --now rke2-agent
