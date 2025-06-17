#!/bin/bash -xv
set -Eeuo pipefail

/opt/rke2/bin/rke2-uninstall.sh || true
/usr/local/bin/rke2-uninstall.sh || true
# echo 0 > /sys/class/net/eth4/device/sriov_numvfs
# echo 0 > /sys/class/net/eth5/device/sriov_numvfs

pkill -9 -f rke2

# for calico
ipset destroy
