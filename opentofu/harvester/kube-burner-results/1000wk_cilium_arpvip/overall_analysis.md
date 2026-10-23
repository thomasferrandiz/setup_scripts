Here's a summary you can send as-is. It leaves out internal node names and the run-by-run details.

---

**Running large RKE2 clusters (~1000 nodes): what we learned from load testing**

**Test setup**
- RKE2 with Cilium.
- 3 control-plane nodes, each 8 vCPU and 16 GiB RAM. They are dedicated to the control plane (tainted `CriticalAddonsOnly`).
- About 1000 worker VMs.
- A single API virtual IP (VIP) managed by kube-vip in ARP mode.
- Load generated with kube-burner: creating, reading, patching and deleting up to 2000 namespaces of Deployments, Services, ConfigMaps and Secrets.

**Key findings**

1. **1000 idle nodes already put a steady load on the control plane.** Before any workload ran, the API server was handling about 100–150 requests/s, mostly node heartbeats. It held about 50k open watches and used about 5.5 GiB of memory.
2. **A single VIP sends everything to one API server.** In ARP mode, all clients use the API server on the node holding the VIP. That node ran out of CPU first, using about 7 of its 8 cores, while the other two control-plane nodes stayed mostly idle.
3. **Object creation hits a limit at about 90 objects/s** (about 230 create requests/s). Raising the client rate further did not speed things up. It only made create requests slower, going from about 0.1 s to 0.7–0.9 s.
4. **Reads scale well.** Around 200 GET requests/s stayed at about 7 ms each.
5. **Bulk deletes are the riskiest operation.** Deleting thousands of Services or Deployments at once triggers a large burst of work across the cluster: cleanup of dependent objects, endpoint updates and notifications to every node's networking agent. During these bursts we saw:
   - Control-plane CPU between 80% and 100%.
   - Throttling (HTTP 429) of system components, including node heartbeats.
   - Delete requests timing out (HTTP 504), although the objects were removed later.
   - The API server dropping tens of thousands of watches, which then reconnect.
6. **Namespace deletion runs at a fixed speed** of about 200 deletes/s, whatever the client rate. Removing 2000 loaded namespaces took 13–14 minutes.
7. **etcd was not the bottleneck.** Disk latency stayed healthy (99th-percentile fsync of 8–16 ms) and each etcd member used less than 1 CPU core. However:
   - The etcd member on the overloaded API-server node fell behind during bursts.
   - The etcd database file grew from 110 to 470 MiB and only shrinks after a defragmentation.
8. **Restarting control-plane nodes can pile watches onto one API server.** After a rolling restart, the API server holding the VIP started with about 30% more watches than before. That run was the one that failed under bulk deletes.

**Recommendations**

- **Spread API traffic across all control-plane nodes.** Use a load balancer, such as kube-vip in BGP mode or an external load balancer, instead of a single ARP VIP.
- **Size the control plane above 8 vCPU per node** for clusters of about 1000 nodes with high object churn. Keep these nodes dedicated, with workloads tainted off them.
- **Use low-latency SSD/NVMe storage for etcd,** and monitor it. You can expose etcd metrics with `etcd-expose-metrics: true`; port 2381 is unauthenticated, so restrict access to it.
- **Throttle bulk deletions.** Delete in batches or at a lower client rate (for example around 50 requests/s), and allow 10–15 minutes for large namespace cleanups.
- **Review API Priority and Fairness settings** so that system controllers and node heartbeats aren't starved during bursts. Run automation as a dedicated service account, not as cluster-admin: admin requests skip throttling and can crowd out everything else.
- **Defragment etcd during maintenance windows** (`etcdctl defrag`, one member at a time) after large churn.
- **After restarting control-plane nodes, check the load on each API server** (open watches and memory) before starting heavy operations.

**Caveat:** these results come from one virtualized lab environment. The exact limits depend on hardware, the networking plugin (CNI) and the shape of the workload. Run a load test that matches your own workload before going to production.
