# Harvester RKE2 control plane

For workload density and API server stress testing with CPU/memory sampling,
see the [kube-burner workloads](./kube-burner/README.md).

The cloud-init configuration installs RKE2 server services on `bench-cp-01`,
`bench-cp-02`, and `bench-cp-03`. Each Harvester VirtualMachine carries the
label `node-role=control-plane` (set on the VM object, not as an RKE2/Kubernetes
node label). `bench-cp-01` bootstraps the cluster; `bench-cp-02` and
`bench-cp-03` join it directly at `https://<bench-cp-01 IP>:9345`. Cloud-init
writes the RKE2 config and bootstrap script, then runs that script after
enabling the guest services. Every RKE2 node (servers and workers) gets the
`iptables` package. The `opensuse` user logs in with SSH keys only (password
login is locked). The servers register with the taint
`CriticalAddonsOnly=true:NoExecute`, so ordinary workloads run on the workers
only; pods that must run on the control plane need a
matching toleration. The servers also set `etcd-expose-metrics: true`, so etcd
serves its Prometheus metrics, unauthenticated, on port 2381 of each server's
node IP. The kube-burner runner reads them through the API server
(see [etcd metrics](./kube-burner/README.md#etcd-metrics)).

The VMs connect to `default/vm-net-2085`. The Harvester load balancer cannot
reach backends on this isolated network, so joining servers do not use it.
All three control-plane VMs use `wait_for_lease = true`: OpenTofu waits for
the bootstrap DHCP address before rendering the joining servers' cloud-init,
then waits for all server addresses before rendering the HAProxy backends.
Use the `virtual_machines` output to obtain the VM addresses, including the
load balancers.

## API load balancing

Two dedicated DHCP VMs, `bench-lb-01` and `bench-lb-02`, run HAProxy and
Keepalived on vm-net-2085 (2 vCPU, 4 GiB RAM, 20 GiB disk each). They do not
join RKE2. Keepalived binds the static VIP `rke2_api_vip`
(default `192.168.64.253/19`) to `eth0` on the healthy higher-priority VM.
If HAProxy stops or the active VM fails, the backup takes over.
Workers join through it at
`https://192.168.64.253:9345`, and the Kubernetes API is reachable at
`https://192.168.64.253:6443`. The VIP is added to every server's `tls-san`.
vm-net-2085's DHCP pool covers the whole `/19`, so the VIP must be reserved or
excluded on its DHCP server to avoid a conflict. kube-vip is no longer deployed.

[haproxy.cfg](./haproxy.cfg) forwards both ports to all three server DHCP
addresses using TCP/TLS passthrough and `leastconn`. It balances new connections,
not individual requests: HTTP/2 requests and long-lived watches can still
produce uneven backend load. TCP health checks remove unreachable backends;
they do not verify API readiness. Client/server inactivity timeouts are one hour,
TCP keepalives are enabled, and the connection limit is 100,000 with an increased
systemd file-descriptor limit. Monitor both proxy capacity and per-server API
metrics during benchmarks. Local HAProxy statistics are available through
`/var/lib/haproxy/stats` (for example, `echo 'show stat' | sudo socat stdio
unix-connect:/var/lib/haproxy/stats` if `socat` is installed). This path is
allowed by openSUSE's packaged HAProxy AppArmor profile; `/run/haproxy.sock`
is not, and using it prevents HAProxy from starting even if its syntax check passes.

[keepalived.conf](./keepalived.conf) uses multicast VRRP (IP protocol 112,
destination `224.0.0.18`, virtual router ID 51). The network must allow VRRP
between the two VMs, gratuitous ARP for the VIP, and client connections on TCP
6443/9345. Use a VRID not already in use on this L2 network. Do not deploy this
configuration if VRRP multicast is filtered: both VMs could claim the VIP.
The health script checks the HAProxy service, not backend health, so a common
backend outage does not make the VIP oscillate.

Place the two load-balancer VMs on **different Harvester hosts** for host-failure
redundancy. This provider configuration selects network-capable hosts but does
not enforce VM anti-affinity; verify placement in `virtual_machines` and configure
Harvester placement rules as needed.

Load-balancer cloud-init is rendered only after all server leases are available.
Workers are created after the load-balancer VMs; their install scripts still
wait for the VIP supervisor because VM readiness does not mean HAProxy
or RKE2 has finished starting. The load-balancer VMs do not use
`wait_for_lease`: their individual addresses are not required for registration
or proxy configuration, and delayed guest-agent IP reporting must not block an
otherwise working VIP. Their output addresses may initially be empty; the
provider may also report the VIP rather than the DHCP address on the active VM.
Keep DHCP leases stable across reboots (prefer
DHCP reservations). If a control-plane address changes, update HAProxy on both
load balancers and validate/reload it; existing cloud-init does not rerun when
OpenTofu updates its secret. The same applies to the direct bootstrap address
used by joining servers.

This setup is intended for a **fresh cluster**. Server cloud-init now comes from
the tracked [server-cloud-config.yml](./server-cloud-config.yml); the legacy
gitignored `cloud-config.yml` is no longer used. Configuration validation runs
on each load balancer before services are started; check `cloud-init status
--long` and `journalctl -u haproxy -u keepalived` if startup fails.

After deployment:

1. Check both load balancers with `sudo cloud-init status --wait` and
   `sudo systemctl status haproxy keepalived`.
2. Confirm only one VM has `192.168.64.253` in `ip -4 addr show dev eth0`.
3. From the jump host, use a kubeconfig targeting the VIP to run `kubectl get
   nodes` and inspect HAProxy statistics to confirm all three backends are UP.
4. Stop HAProxy on the active VM, confirm the VIP moves to its peer and new API
   connections succeed, then start HAProxy again. Existing connections can be
   interrupted during failover and must reconnect.

`rke2_worker_count` (default 1000, allowed range 0-1000) worker VMs,
`bench-wk-01` to `bench-wk-1000` (existing two-digit names are preserved),
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
to scale to 1000 workers (the default and maximum) without having them all join at once:

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
before each next apply. From 50 workers, the counts are 100, 150, ..., 1000.
On a fresh deployment it first applies a count of zero to bootstrap the
control plane, load balancers and jump host, then discovers their addresses automatically.

Each readiness gate times out after 30 minutes, and any failed apply stops
the script immediately. Rerun the same command after resolving a failure:
partially created batches are discovered from state and completed without
scaling down. Unexpected worker names and targets below the highest existing
worker number are rejected. Do not run another apply or scaling script concurrently;
the OpenTofu state lock covers each apply, not the entire sequence. Applies
are auto-approved and include any other pending configuration changes, so
review those changes first.

**Batching is enforced by the script, not by `main.tf`.** A plain `tofu apply`
uses the default count of 1000 and can start all missing workers together.
During an interrupted rollout, use the script to resume, not a plain apply.
VM creation/guest-agent readiness and OpenTofu's `-parallelism` alone do not
guarantee that Kubernetes nodes have finished joining.

### Pod-network capacity

The rebuilt cluster uses pod CIDR `10.44.0.0/14`, defined by
`local.rke2_cluster_cidr` in `main.tf` and passed to every server's cloud-init.
With Kubernetes' default `/24` per-node allocation, it provides 1,024 node
blocks, enough for 1000 workers plus three control-plane nodes (21 spare). Cilium uses
these allocations through Kubernetes IPAM. The service CIDR remains
`10.43.0.0/16`; neither it nor vm-net-2085 overlaps the pod range.

This CIDR is for a fresh cluster, not an in-place migration of the old
`10.42.0.0/16` cluster. The `server-cloud-config.yml` template must
use `cluster-cidr: ${rke2_cluster_cidr}` in its RKE2 config. Keep the pod range
free of overlap with any other networks routed to the cluster.

The scaling and benchmark tests use mocked OpenTofu/SSH/kubectl commands
without accessing Harvester. Template tests use local `tofu console` and Ruby's
YAML parser with synthetic inputs:

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
replacement. The Cilium operator also tolerates the control-plane
`CriticalAddonsOnly` taint (the agent and envoy already tolerate all taints).

Terraform generates a shared RKE2 token and stores it in the Terraform state.
Terraform stores each VM's cloud-init in a Harvester secret to avoid the
Harvester inline user-data size limit. The cloud-init, including the shared
token, is also stored in Terraform state; protect the state file accordingly.
Cloud-init runs on first boot, so already initialized VMs will need to have the
updated cloud-init applied or `/usr/local/sbin/rke2-server-sles.sh` run
manually.
