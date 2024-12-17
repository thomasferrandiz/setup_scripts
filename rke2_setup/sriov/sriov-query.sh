#!/bin/bash -xv
set -Eeuo pipefail

MSTCONFIG=$(which mstconfig)

# query pci bus for mellanox devs
while IFS= read -r line; do
    echo "$line"
    devs+=("`echo $line | awk '{ print $1 }'`")
done <<< "`lspci | grep 'Mellanox' | grep -v 'Virtual Function'`"

# set the device configuration
for dev in ${devs[@]}; do
    ${MSTCONFIG} -y -d ${dev} query | egrep 'SRIOV_EN|NUM_OF_VFS'
done
