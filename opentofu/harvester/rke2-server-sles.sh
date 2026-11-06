#!/bin/bash
set -euo pipefail

config_file=/etc/rancher/rke2/config.yaml

zypper --non-interactive refresh
zypper --non-interactive install -y curl

# Every API server node deploys the same manifests, so they apply whichever
# joins first; etcd-only nodes run no deploy controller.
if ! grep -q '^disable-apiserver: *true' "$config_file"; then
  api_vip=$(awk '$1 == "tls-san:" { getline; print $2; exit }' "$config_file")
  if [[ -z "$api_vip" ]]; then
    echo "No tls-san API VIP in $config_file" >&2
    exit 1
  fi
  manifest_dir=/var/lib/rancher/rke2/server/manifests
  mkdir -p "$manifest_dir"
  cat > "$manifest_dir/rke2-cilium-config.yaml" <<EOF
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
    updateStrategy: {rollingUpdate: {maxUnavailable: 10%}}
    # Bootstrap URLs only. With more than one, the agent switches to the
    # kubernetes Service once synced, and Cilium's socket LB picks a random API
    # server on every new connection, so GOAWAY spreads the agents. Through
    # localhost alone they stay on one server until it fails.
    k8s:
      apiServerURLs: "https://${api_vip}:6443 https://127.0.0.1:6443"
    ipam:
      mode: kubernetes
    ipv4:
      enabled: true
    ipv6:
      enabled: false
    # Agent metrics on port 9962 of every node, read by the kube-burner runner
    # through the API server's pod proxy.
    prometheus:
      enabled: true
    # The defaults plus the control-plane CriticalAddonsOnly taint; the agent
    # and envoy already tolerate every taint.
    operator:
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
        - key: node-role.kubernetes.io/master
          operator: Exists
        - key: node-role.kubernetes.io/etcd
          operator: Exists
        - key: node.kubernetes.io/not-ready
          operator: Exists
        - key: node.cloudprovider.kubernetes.io/uninitialized
          operator: Exists
EOF
  # The chart rolls the per-worker DaemonSet one pod at a time; at 10%, a
  # rebalance restart of 1,000 pods takes minutes instead of hours.
  cat > "$manifest_dir/rke2-traefik-config.yaml" <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    updateStrategy:
      rollingUpdate:
        maxUnavailable: 10%
EOF
  # The suggested kube-system-service-accounts FlowSchema distinguishes flows
  # by namespace, so every kube-system agent shares one flow, limited to 6
  # queues of 50: Cilium's watch re-establishments got 429 queue-full. Leases
  # still match system-leader-election first (precedence 100).
  cat > "$manifest_dir/cilium-apf.yaml" <<'EOF'
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: cilium
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 40
    lendablePercent: 50
    limitResponse:
      type: Queue
      queuing:
        queues: 64
        handSize: 8
        queueLengthLimit: 250
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: cilium
spec:
  priorityLevelConfiguration:
    name: cilium
  matchingPrecedence: 850
  distinguisherMethod:
    type: ByUser
  rules:
    - subjects:
        - kind: ServiceAccount
          serviceAccount:
            name: cilium
            namespace: kube-system
        - kind: ServiceAccount
          serviceAccount:
            name: cilium-operator
            namespace: kube-system
      resourceRules:
        - verbs: ["*"]
          apiGroups: ["*"]
          resources: ["*"]
          clusterScope: true
          namespaces: ["*"]
      nonResourceRules:
        - verbs: ["*"]
          nonResourceURLs: ["*"]
EOF
  # The rke2-traefik DaemonSet runs on every worker and watches about 20
  # resources per pod; in kube-system-service-accounts its re-watches after
  # force-closed Service watches got 429 queue-full. All pods share one
  # ServiceAccount, hence one flow: the hand of 8 queues of 500 is what
  # absorbs the burst.
  cat > "$manifest_dir/traefik-apf.yaml" <<'EOF'
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: traefik
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 20
    lendablePercent: 50
    limitResponse:
      type: Queue
      queuing:
        queues: 64
        handSize: 8
        queueLengthLimit: 500
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: traefik
spec:
  priorityLevelConfiguration:
    name: traefik
  matchingPrecedence: 860
  distinguisherMethod:
    type: ByUser
  rules:
    - subjects:
        - kind: ServiceAccount
          serviceAccount:
            name: rke2-traefik
            namespace: kube-system
      resourceRules:
        - verbs: ["*"]
          apiGroups: ["*"]
          resources: ["*"]
          clusterScope: true
          namespaces: ["*"]
      nonResourceRules:
        - verbs: ["*"]
          nonResourceURLs: ["*"]
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

cat >> /home/opensuse/.profile <<'EOF'
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin/
alias k=kubectl
EOF

# k9s via tarball (no .deb on SLES)
curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused \
  https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_amd64.tar.gz \
  -o /tmp/k9s_Linux_amd64.tar.gz
tar -xzf /tmp/k9s_Linux_amd64.tar.gz -C /usr/local/bin k9s
rm /tmp/k9s_Linux_amd64.tar.gz

curl -fsSL --retry 3 --retry-delay 5 https://get.rke2.io -o /tmp/install-rke2.sh
env INSTALL_RKE2_CHANNEL=stable bash /tmp/install-rke2.sh
systemctl enable --now rke2-server
