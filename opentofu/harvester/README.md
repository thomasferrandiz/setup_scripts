# Harvester RKE2 control plane

The cloud-init configuration installs RKE2 server services on `bench-cp-01`,
`bench-cp-02`, and `bench-cp-03`. Each Harvester VirtualMachine carries the
label `node-role=control-plane` (set on the VM object, not as an RKE2/Kubernetes
node label). The first VM bootstraps the cluster; the other two
join it through the load balancer. Cloud-init writes the RKE2 config and
bootstrap script, then runs that script after enabling the guest services.

The VMs connect to `default/vm-net-2085`. The load balancer at
`10.113.75.205` (`rke2_api_endpoint`) must forward TCP ports **6443** and
**9345** to all three VM addresses. Change the variable in `main.tf` if the
address changes. Use the `virtual_machines` output to obtain the VM addresses.

Note: the Harvester provider sets `labels` only on the VirtualMachine object,
not on its VMI template. Harvester's load balancer `backendServerSelector`
matches VMIs, so a `node-role=control-plane` selector will not find these VMs
by itself. Every VMI does carry `harvesterhci.io/vmName=<vm name>`, which can be
used as the selector instead.

RKE2's bundled Cilium chart is configured for kube-proxy replacement and
IPv4-only networking (`10.42.0.0/16` pod CIDR and `10.43.0.0/16` service
CIDR). The guest kernel must be version 5.8 or newer for Cilium kube-proxy
replacement.

Terraform generates a shared RKE2 token and stores it in the Terraform state.
Terraform stores each VM's cloud-init in a Harvester secret to avoid the
Harvester inline user-data size limit. The cloud-init, including the shared
token, is also stored in Terraform state; protect the state file accordingly.
Cloud-init runs on first boot, so already initialized VMs will need to have the
updated cloud-init applied or `/usr/local/sbin/rke2-server-sles.sh` run
manually.
