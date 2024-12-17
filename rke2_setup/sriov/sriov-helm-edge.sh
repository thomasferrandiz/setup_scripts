#!/bin/bash -xv
set -Eeuo pipefail

REPO_NAME="suse-edge"
REPO_URL="https://suse-edge.github.io/charts"

helm repo add ${REPO_NAME} ${REPO_URL} 
helm repo update
helm install -n kube-system sriov-crd ${REPO_NAME}/sriov-crd
helm install -n kube-system sriov ${REPO_NAME}/sriov-network-operator
