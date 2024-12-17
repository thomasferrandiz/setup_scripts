
#!/bin/bash -xv
set -Eeuo pipefail

IMAGE=wbitt/network-multitool
TAG=extra
RAND=$(echo $RANDOM | md5sum | head -c 6)
NAME=$(basename $IMAGE-$RAND)

kubectl run $NAME --rm -i --tty --image $IMAGE:$TAG -- bash

# iperf3 -s -p 5252
# iperf3 -c <ip> -p 5252
