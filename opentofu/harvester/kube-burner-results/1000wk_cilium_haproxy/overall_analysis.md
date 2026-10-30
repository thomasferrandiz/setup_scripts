Here's a follow-up you can send as-is. Like the first summary, it leaves out internal node names and the run-by-run details.

---

**Running large RKE2 clusters (~1000 nodes), part 2: spreading API traffic with a load balancer**

**What changed since the first summary**

The first round of tests used a single API virtual IP managed by kube-vip in ARP mode. All clients went to one API server, which ran out of CPU while the other two control-plane nodes stayed mostly idle. For this second round we replaced it with an external load balancer and ran 15 more load tests, tuning one thing at a time.

**Test setup**
- RKE2 with Kubernetes 1.36 and Cilium (kube-proxy replacement).
- 3 control-plane nodes, each 8 vCPU and 16 GiB RAM, dedicated to the control plane. etcd runs on the same nodes.
- About 1000 worker VMs.
- API virtual IP served by HAProxy (TCP mode, `balance leastconn`) and Keepalived, on two small dedicated VMs.
- Same kube-burner workload as before: create, read, patch and delete 2000 namespaces of Deployments, Services, ConfigMaps and Secrets. In most runs the namespaces were created first, so the objects were created as fast as the client rate allowed (300 or 150 requests/s).

**Results: first run vs final configuration**

| | Load balancer, default settings | Load balancer + tuning (final run) |
|---|---|---|
| Errors | 0–248 Service creates timed out per run (retried) | **0** |
| Time until all 2000 Deployments were Ready | about 8 minutes | **about 2 minutes** |
| Pod Ready latency (99th percentile) | 3–7 s (23 s on the very first run, with cold image caches) | 5 s |
| Requests rejected by API Priority and Fairness (APF) | 3,100–8,900 | 1,700, only during bulk deletes |
| Cleanup of 2000 namespaces | about 13 minutes | about 12 minutes |

In between, some intermediate runs were much worse (pods taking up to 3 minutes to become Ready, thousands of errors, an API server restart). Each of those problems is explained below, with the fix that removed it.

**Key findings**

1. **A load balancer removes the single-server bottleneck.** In the first run with HAProxy, all three API servers shared the load, create requests stayed at 23–59 ms (up to 0.9 s with the ARP VIP), and the bulk-delete timeouts and 5xx errors from the first round were gone.

2. **The load balancer only balances the clients that go through it.** In RKE2, the kubelet and (by default) the Cilium agent on each node connect through a local proxy on `127.0.0.1:6443`. That proxy stays on one API server and only moves when its connection fails.
   - So after an API server restarts (upgrade, reboot, configuration change), it gets almost no node clients back. The node agents pile onto the remaining servers. We measured splits as uneven as 68k / 3k / 46k open connections (goroutines) across the three servers.
   - This was the main cause of variation between runs. With an uneven split, one server ran at 100 % CPU, its watchers were dropped and re-established in storms, and pods waited up to 3 minutes for their network setup.
   - The API server's `goaway-chance` option did not fix it. It only helps clients that come through the load balancer; node agents just reconnect to the same server.
   - **What worked:** after restarting control-plane nodes, restart the node agents in small batches (the Cilium DaemonSet, then `rke2-agent` on the workers), so that they reconnect across all servers. Check that the servers then hold a similar number of connections. With an even split, pod Ready latency went from 37–167 s (99th percentile) to 5 s.

3. **kube-controller-manager's default limits set the pace of Deployments.** With default settings, the cluster processed about 4 Deployments/s, whatever the client rate, so 2000 Deployments took about 8 minutes, and patching them about 12 minutes. The controllers were waiting on their own client-side rate limit, not on the API server.
   - Raising `kube-api-qps` to 100, `kube-api-burst` to 200, and `concurrent-deployment-syncs` / `concurrent-replicaset-syncs` to 20 cut this to about 3 minutes (2 minutes once the load was balanced), and patching to under 3 minutes.
   - The trade-off: the work now reaches the API servers, etcd and the nodes all at once. On an unbalanced control plane, it made things worse at first.

4. **The networking agents need their own API Priority and Fairness level.** By default, every service account in `kube-system` (Cilium, the Cilium operator, the ingress controller and other controllers) shares one APF flow. When one of them re-established many watches, all of them were rejected with HTTP 429.
   - For Cilium, that meant slow pod network setup: up to 19–57 s per pod, while Cilium itself needed only milliseconds.
   - A dedicated priority level and FlowSchema for the Cilium service accounts brought Cilium's rejections to 0. The remaining rejections only happen during bulk deletes, and only affect other kube-system controllers, which retry.

5. **Service creation has a hard limit of about 30 Services/s on this hardware.** In Kubernetes 1.36, each API server assigns ClusterIPs one at a time, and each assignment is a write to etcd.
   - With 8 vCPU nodes under load, each assignment took 75–160 ms, so the three servers together managed about 30 Services/s.
   - When Services were created faster, they queued, and those that waited more than 60 s failed with a timeout (up to 904 in one run; all succeeded on retry). Other object types never timed out.
   - At half the client rate (150 requests/s, about 37 Services/s), there were no timeouts. The longest waits were about 40 s, so this is close to the limit.
   - Kubernetes 1.38 makes ClusterIP allocation concurrent (kubernetes/kubernetes#142758), which should remove this limit.

6. **etcd was healthy as long as its database stayed small and the control plane stayed balanced.**
   - Disk latency stayed low in every run (fsync of a few milliseconds).
   - In one run, the database had grown to 830 MiB in use. etcd fell behind applying writes and rejected about 1,100 creates with `etcdserver: too many requests`, and one API server restarted. After compaction and defragmentation, this never happened again.
   - Under load, etcd's write latency follows the control-plane CPU, because it shares the nodes with the API server. Seen from the API servers, writes took about 10 ms in a run where two of the three nodes were lightly loaded, and about 60–70 ms when all three nodes were at 80–95 % CPU.

7. **Memory gets tight on the API server that holds the most connections.** It reached 8–9.6 GiB on 16 GiB nodes. In the run where the database had grown, one API server restarted at 8.1 GiB.

8. **One issue is still open.** In 3 of the 15 runs, the load-testing client lost one HTTP/2 connection through the virtual IP, and the 60–130 requests in flight on it failed. No API server restarted or reported errors at those times, and we haven't found the cause yet. Clients that retry are not affected.

**Recommendations**

These add to the recommendations of the first summary.

- **Use a load balancer for the API (HAProxy with Keepalived, or kube-vip in BGP mode), and plan for rebalancing.** After every control-plane restart, restart the node agents in batches, and check that the API servers hold similar numbers of open connections before heavy operations. Doing control-plane restarts one node at a time does not avoid this.
- **Tune kube-controller-manager for high churn.** In RKE2, set in the server config:
  ```yaml
  kube-controller-manager-arg:
    - kube-api-qps=100
    - kube-api-burst=200
    - concurrent-deployment-syncs=20
    - concurrent-replicaset-syncs=20
  ```
  Raise these only once the control plane is sized and balanced for the extra load.
- **Give the CNI agents their own API Priority and Fairness level.** Add a PriorityLevelConfiguration and a FlowSchema that match the Cilium (or other CNI) service accounts, with a precedence below the default `kube-system-service-accounts` schema (lower numbers win). That way, a burst from another kube-system controller can't slow pod network setup.
- **Plan Service creation below about 30 Services/s** on 1.36 with 8 vCPU control-plane nodes. For bulk creation, use a client rate of about 150 requests/s or less. More control-plane CPU or Kubernetes 1.38 raises this limit.
- **Size control-plane nodes above 8 vCPU and 16 GiB** for clusters of this size with high churn. All three nodes reached 80–95 % CPU even when perfectly balanced, and the busiest API server used up to 9.6 GiB.
- **Keep etcd small.** Monitor its in-use database size, and defragment it during maintenance windows after large churn, one member at a time and the leader last.
- **Avoid putting the etcd leader and the kube-controller-manager leader on the same node** if you can. In our tests, the API server on that node was the slowest to create Services.

**Caveat:** as before, these results come from one virtualized lab environment. The exact limits depend on hardware, the CNI, the Kubernetes version and the shape of the workload. Run a load test that matches your own workload before going to production.
