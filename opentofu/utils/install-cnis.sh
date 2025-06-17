#!/bin/sh

mkdir -p /opt/cni/bin
curl -O -L https://github.com/containernetworking/plugins/releases/download/v1.7.1/cni-plugins-linux-amd64-v1.7.1.tgz
tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-v1.7.1.tgz
