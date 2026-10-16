# Harvester RKE2 control plane

The cloud-init configuration installs RKE2 server services on `bench-cp-01`,
`bench-cp-02`, and `bench-cp-03`. Each Harvester VirtualMachine carries the
label `node-role=control-plane` (set on the VM object, not as an RKE2/Kubernetes
node label). `bench-cp-01` bootstraps the cluster; `bench-cp-02` and
`bench-cp-03` join it directly at `https://<bench-cp-01 IP>:9345`. Cloud-init
writes the RKE2 config and bootstrap script, then runs that script after
enabling the guest services.

The VMs connect to `default/vm-net-2085`. The Harvester load balancer cannot
reach backends on this isolated network, so joining servers do not use it.
`bench-cp-01` is a separate resource with `wait_for_lease = true`: OpenTofu
waits for its DHCP address before rendering the joining servers' cloud-init.
If `bench-cp-01` is recreated and gets a new address, the existing joining
servers keep the old one and must be updated or recreated. Use the
`virtual_machines` output to obtain the VM addresses.

kube-vip (`kube-vip.yaml`, deployed by cloud-init into the RKE2 server
manifests directory) runs as a DaemonSet on the control-plane nodes in ARP
control-plane mode. The leader binds the static VIP `rke2_api_vip`
(default `192.168.64.253` on vm-net-2085) to `eth0`. Workers join through it at
`https://192.168.64.253:9345`, and the Kubernetes API is reachable at
`https://192.168.64.253:6443`. The VIP is added to every server's `tls-san`.
vm-net-2085's DHCP pool covers the whole `/19`, so the VIP must be reserved or
excluded on its DHCP server to avoid a conflict. kube-vip's DHCP mode is not
used: it needs the `macvlan` module, which is missing from the image's
`kernel-default-base`, and the DHCP server did not reliably answer its requests.

`rke2_worker_count` (default 750, allowed range 0-750) worker VMs,
`bench-wk-01` to `bench-wk-750` (existing two-digit names are preserved),
have 1 CPU, 2 GiB RAM and a 20 GiB disk on the same base image and a single
NIC on vm-net-2085. Their cloud-init (one Harvester secret per worker) writes
an RKE2 agent config pointing at `https://<rke2_api_vip>:9345` with the shared
token, then runs `rke2-agent-sles.sh`, which waits for the supervisor on the VIP
and installs `rke2-agent` pinned to `rke2_agent_version`. Keep that version equal
to the servers' version (agents must not be newer than the servers). The
`opensuse` user accepts the Harvester `default/tferrandiz` key and
`bench.key.pub`, so workers are reachable from `bench-net-01`; password login is
locked.

## Scaling workers in batches

Use [scale-workers.sh](./scale-workers.sh) instead of a direct `tofu apply`
to scale to 750 workers (the default and maximum) without having them all join at once:

```bash
cd opentofu/harvester
tofu init
bash ./scale-workers.sh
# Optional smaller target, including a final batch of fewer than 50:
bash ./scale-workers.sh 125
```

The script requires local `tofu`, `jq`, and `ssh`. It discovers the primary
`vm-net` IP of `bench-net-01` from the `virtual_machines` OpenTofu output after
each apply and connects as `opensuse`. OpenTofu waits for that interface's
DHCP lease during creation. It authenticates with the local private key
`jump_host.key` in this directory (gitignored; must be readable and match the
Harvester `default/tferrandiz` public key), ignoring other agent keys. The
jump host uses
its existing `bench.key` to reach `bench-cp-01`, where passwordless sudo runs
RKE2's bundled kubectl. New SSH host keys are accepted on first contact;
changed host keys are rejected. No local kubeconfig or direct access to
vm-net-2085 is required.

The script reads existing worker VM resources from state, reconciles up to
the highest existing worker number (recreating any missing lower-numbered
workers left by an interrupted batch), and waits for all three control-plane nodes and every existing
worker to report Kubernetes `Ready=True`. It then applies increasing worker
counts in groups of at most 50, waiting for **all expected nodes** to be Ready
before each next apply. From 50 workers, the counts are 100, 150, ..., 750.
On a fresh deployment it first applies a count of zero to bootstrap the
control plane and jump host, then discovers their addresses automatically.

Each readiness gate times out after 30 minutes, and any failed apply stops
the script immediately. Rerun the same command after resolving a failure:
partially created batches are discovered from state and completed without
scaling down. Unexpected worker names and targets below the highest existing
worker number are rejected. Do not run another apply or scaling script concurrently;
the OpenTofu state lock covers each apply, not the entire sequence. Applies
are auto-approved and include any other pending configuration changes, so
review those changes first.

**Batching is enforced by the script, not by `main.tf`.** A plain `tofu apply`
uses the default count of 750 and can start all missing workers together.
During an interrupted rollout, use the script to resume, not a plain apply.
VM creation/guest-agent readiness and OpenTofu's `-parallelism` alone do not
guarantee that Kubernetes nodes have finished joining.

### Pod-network capacity

The rebuilt cluster uses pod CIDR `10.44.0.0/14`, defined by
`local.rke2_cluster_cidr` in `main.tf` and passed to every server's cloud-init.
With Kubernetes' default `/24` per-node allocation, it provides 1,024 node
blocks, enough for 750 workers plus three control-plane nodes. Cilium uses
these allocations through Kubernetes IPAM. The service CIDR remains
`10.43.0.0/16`; neither it nor vm-net-2085 overlaps the pod range.

This CIDR is for a fresh cluster, not an in-place migration of the old
`10.42.0.0/16` cluster. The local, gitignored `cloud-config.yml` template must
use `cluster-cidr: ${rke2_cluster_cidr}` in its RKE2 config. Keep the pod range
free of overlap with any other networks routed to the cluster.

The batching tests use mocked OpenTofu and SSH commands without accessing
Harvester:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

The standalone `bench-net-01` VM has 1 CPU, 2 GiB RAM, a 20 GiB disk using the
same base image, with its main interface on `default/vm-net` and its secondary
interface on `default/vm-net-2085`. Its cloud-init installs the guest agent and authorizes the
public key read from Harvester's `default/tferrandiz` SSH key for the `opensuse`
user (password login is locked). The key is also included in the top-level
`ssh_authorized_keys` section. Userdata is base64-encoded to bypass the
provider's inline SSH-key append logic, which does not recognize the quoted
YAML keys emitted by `yamlencode` and would append a duplicate section.
This VM does not install or join RKE2.

For VM-to-VM SSH, the local key pair `bench.key` / `bench.key.pub` (in this
directory; the private key is gitignored and must be provided locally) is used:
`bench.key.pub` is added to the `opensuse` user's authorized keys on the
`bench-cp-*` VMs, and `bench-net-01` gets `bench.key`, `bench.key.pub`, and an
`~/.ssh/config` selecting `bench.key` in `/home/opensuse/.ssh`. The
`bench-net-01` cloud-init is stored in a Harvester secret so the private key is
not embedded in the VM spec; it is still stored in Terraform state. Like the
rest of cloud-init, this only applies on first boot.

Explicit cloud-init network data enables DHCPv4 on both `eth0` (`vm-net`)
and `eth1` (`vm-net-2085`). Without it, the image's fallback network configuration
only enables the first interface. Both VLANs require an external DHCP service;
attaching a Harvester VLAN network does not itself assign an address.
For an already initialized VM, updating cloud-init does not automatically
reconfigure the guest. Configure its missing interface through the console or
guest agent, or recreate the VM only if its disk contents are disposable.

Note: the Harvester provider sets `labels` only on the VirtualMachine object,
not on its VMI template. Harvester's load balancer `backendServerSelector`
matches VMIs, so a `node-role=control-plane` selector will not find these VMs
by itself. Every VMI does carry `harvesterhci.io/vmName=<vm name>`, which can be
used as the selector instead.

RKE2's bundled Cilium chart is configured for kube-proxy replacement and
IPv4-only networking (`10.44.0.0/14` pod CIDR and `10.43.0.0/16` service
CIDR). The guest kernel must be version 5.8 or newer for Cilium kube-proxy
replacement.

Terraform generates a shared RKE2 token and stores it in the Terraform state.
Terraform stores each VM's cloud-init in a Harvester secret to avoid the
Harvester inline user-data size limit. The cloud-init, including the shared
token, is also stored in Terraform state; protect the state file accordingly.
Cloud-init runs on first boot, so already initialized VMs will need to have the
updated cloud-init applied or `/usr/local/sbin/rke2-server-sles.sh` run
manually.
