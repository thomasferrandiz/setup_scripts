#!/bin/bash -xv
set -Eeuo pipefail

REPO_NAME="edge-charts"
REPO_URL="https://raw.githubusercontent.com/suse-edge/charts/main" 

helm repo add ${REPO_NAME} ${REPO_URL} 
helm repo update
helm install -n kube-system sriov-crd ${REPO_NAME}/sriov-crd
helm install -n kube-system sriov ${REPO_NAME}/sriov-network-operator

