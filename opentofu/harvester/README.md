# Harvester RKE2 control plane

For workload density and API server stress testing with CPU/memory sampling,
see the [kube-burner workloads](./kube-burner/README.md).

The cloud-init configuration installs RKE2 server services on `bench-cp-01`,
`bench-cp-02`, and `bench-cp-03` (the default `stacked` control plane; see
[control-plane topologies](#control-plane-topologies) for dedicated etcd nodes).
Each Harvester VirtualMachine carries the
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
(see [etcd metrics](./kube-burner/README.md#etcd-metrics)). They also pass
`bind-address=0.0.0.0` and
`authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics` to
kube-controller-manager, which then serves its metrics without authorization on
port 10257 of the node IP
(see [kube-controller-manager metrics](./kube-burner/README.md#kube-controller-manager-metrics)).
They also raise kube-controller-manager's client limits and worker counts
(`kube-api-qps=100`, `kube-api-burst=200`, `concurrent-deployment-syncs=20`,
`concurrent-replicaset-syncs=20`). With the defaults (20, 30, 5 and 5), the
controllers throttled themselves on 1000 nodes and took ~8 minutes to make 2000
Deployments Ready (see
[run 07](./kube-burner-results/1000wk_cilium_haproxy/run_07_analysis.md)).
The API servers run with `goaway-chance=0.001`. HAProxy balances TCP
connections, so without it long-lived clients of the VIP, such as kube-burner,
stay on whichever API server they first reached (see
[run 10](./kube-burner-results/1000wk_cilium_haproxy/run_10_analysis.md)).
goaway does not rebalance kubelets, which connect through the rke2-agent local
load balancer on `127.0.0.1:6443`. That load balancer stays on one server until
a connection to it fails (see
[run 11](./kube-burner-results/1000wk_cilium_haproxy/run_11_analysis.md)).
The Cilium agents avoid it: they are given two bootstrap URLs
(`k8s.apiServerURLs`, the VIP and `127.0.0.1`), and then switch to the
`kubernetes` Service, where Cilium's socket load balancer picks a random API
server for every new connection. After a control-plane restart,
`kube-burner/rebalance.sh` restarts Cilium and the rke2-agents in batches to
spread the connections again (see
[rebalancing](./kube-burner/README.md#rebalancing-after-a-control-plane-restart)).

The VMs connect to `default/vm-net-2085`. The Harvester load balancer cannot
reach backends on this isolated network, so joining servers do not use it.
All server VMs use `wait_for_lease = true`: OpenTofu waits for
the bootstrap DHCP address before rendering the joining servers' cloud-init,
then waits for all server addresses before rendering the HAProxy backends.
Use the `virtual_machines` output to obtain the VM addresses, including the
load balancers.

## Control-plane topologies

`rke2_control_plane` selects the server layout:

- `stacked` (default): `bench-cp-01`..`03` each run etcd and the control plane.
- `dedicated-etcd`: `bench-etcd-01`..`03` run only etcd (`disable-apiserver`,
  `disable-controller-manager`, `disable-scheduler`) and `bench-cp-01`..`02`
  run only the control plane (`disable-etcd`). `bench-etcd-01` bootstraps the
  cluster, since a control-plane-only server cannot be the first one, and
  every other server joins at `https://<bench-etcd-01 IP>:9345`. The etcd VMs
  carry the Harvester label `node-role=etcd`.

Etcd-only servers keep `etcd-expose-metrics` and the `CriticalAddonsOnly`
taint, but not the kube-apiserver or kube-controller-manager arguments. HAProxy
only forwards to servers that run the API server (the `haproxy_config` output).
`rke2-server-sles.sh` writes the Cilium HelmChartConfig and `cilium-apf.yaml`
manifests on every API server, since etcd-only servers do not apply manifests;
clusters created before this change only have them on `bench-cp-01`. Keep
manual edits to these manifests identical on every API server.

`rke2_server_roles` (a map of server name to `all`, `etcd` or
`control-plane`) overrides the topology with any intermediate layout; it is
used by the migration below and is not meant to be set by hand. The
`rke2_servers` output records the bootstrap server and roles of the last apply.

To deploy a new cluster with dedicated etcd nodes:

```bash
CONTROL_PLANE=dedicated-etcd bash ./scale-workers.sh
```

`scale-workers.sh` detects the topology of an existing cluster from the server
VMs in state, so `CONTROL_PLANE` is only needed for a fresh deployment. It
refuses a `CONTROL_PLANE` that differs from the deployed one, and refuses to
run while the server VMs match neither topology (a migration in progress).

### Migrating a stacked cluster to dedicated etcd

[migrate-to-dedicated-etcd.sh](./migrate-to-dedicated-etcd.sh) converts a
running stacked cluster in place. The worker VMs are not recreated and keep
running, connected through the VIP:

```bash
cd opentofu/harvester
bash ./migrate-to-dedicated-etcd.sh   # ASSUME_YES=yes skips the confirmation
```

It changes one server per step and waits after each one for every server to be
Ready with its role labels, every etcd member to be started (not a learner) and
`etcdctl endpoint health --cluster` to pass:

1. to 3. Add `bench-etcd-01`, `-02` and `-03` (etcd grows from 3 to 6 members).
4. and 5. Replace `bench-cp-03`, then `bench-cp-02`, with control-plane-only VMs.
6. Replace `bench-cp-01`, and make `bench-etcd-01` the bootstrap server with
   `tofu state mv` (neither VM is recreated by the move).
7. Remove `bench-cp-03`.

Etcd keeps quorum and at least two API servers stay up throughout. Before
replacing or removing a server, the script drains it, stops RKE2 on it
(`rke2-killall.sh`), and deletes its node, which makes RKE2 remove its etcd
member (`etcdctl member remove` is used if it is still there after two
minutes). Each step runs `tofu plan` with the current worker count, limited
with `-target` to the server VMs and secrets and the load balancers' cloud-init
secrets. The workers, load-balancer VMs and `bench-net-01` are neither refreshed
nor changed; the provider reports drift on every VM (a `cloudinitdisk` disk
block that is not in the configuration), which a plain apply would push to all
of them. The script applies the saved plan only if it changes no worker and
deletes nothing but the server being replaced; otherwise it stops. After each apply it updates
`/etc/haproxy/haproxy.cfg` on both load balancers (validated with `haproxy
-c`, then reloaded), since their cloud-init only runs on first boot. At the
end, it removes `server:` from `bench-etcd-01`'s RKE2 config and points the
other servers at `bench-etcd-01`, as their original `server:` address (the old
`bench-cp-01`) no longer exists.

The script needs `jump_host.key` like `scale-workers.sh`, `bench.key` on the
jump host, and SSH access to both load balancers by their reported addresses.
If a step fails, fix the cause and rerun the script: it resumes from the roles
of the last successful apply (the `rke2_servers` output). Do not run `tofu
apply` or `scale-workers.sh` before it has completed. Drains evict the pods
running on the servers (only those tolerating `CriticalAddonsOnly`), and API
clients connected to a removed server reconnect; run `kube-burner/rebalance.sh`
afterwards to spread the connections again. The workers' rke2-agents keep
running throughout but may take some time to update their list of servers.

This version of `main.tf` no longer contains the `moved` blocks of the
earlier `bench_bootstrap` refactoring; apply an older checkout first if the
state predates it.

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

[haproxy.cfg](./haproxy.cfg) forwards both ports to the DHCP addresses of
the servers running the API server using TCP/TLS passthrough and `leastconn`. It balances new connections,
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
workers left by an interrupted batch), and waits for every server node and every existing
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
blocks, enough for 1000 workers plus three stacked servers (21 spare) or five
dedicated-etcd servers (19 spare; six servers at the peak of the migration). Cilium uses
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
`rke2-server-sles.sh` reads the API VIP for `k8s.apiServerURLs` from `tls-san`
in the RKE2 config. It also installs `cilium-apf.yaml`, an API Priority and
Fairness FlowSchema that gives the Cilium agents and operator their own priority
level instead of sharing one kube-system flow (see
[API Priority and Fairness for Cilium](./kube-burner/README.md#api-priority-and-fairness-for-cilium)).
The agents serve their Prometheus metrics on port 9962 of
each node
(`prometheus.enabled`), which the kube-burner runner samples on a few workers
(see [kubelet and cilium-agent metrics](./kube-burner/README.md#kubelet-and-cilium-agent-metrics)).

Terraform generates a shared RKE2 token and stores it in the Terraform state.
Terraform stores each VM's cloud-init in a Harvester secret to avoid the
Harvester inline user-data size limit. The cloud-init, including the shared
token, is also stored in Terraform state; protect the state file accordingly.
Cloud-init runs on first boot, so already initialized VMs will need to have the
updated cloud-init applied or `/usr/local/sbin/rke2-server-sles.sh` run
manually.
