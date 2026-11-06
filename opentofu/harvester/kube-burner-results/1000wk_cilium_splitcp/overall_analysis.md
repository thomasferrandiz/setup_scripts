Here's a follow-up to the second summary that you can send as-is. Like the earlier ones, it leaves out internal node names and the run-by-run details.

---

**Running large RKE2 clusters (~1000 nodes), part 3: dedicated etcd nodes and a bigger control plane**

**What changed since the second summary**

At the end of the second round, the three control-plane nodes (API server, controllers and etcd together, 8 vCPU each) reached 80–95 % CPU even when the load was perfectly balanced. For this third round we moved etcd to its own nodes, then grew the control plane, and ran 10 more load tests, changing one thing at a time.

**Test setup**
- RKE2 with Kubernetes 1.36 and Cilium (kube-proxy replacement), as before.
- **Control plane split in two:**
  - **Control-plane nodes** run the API server, controller manager and scheduler. We started with 2 nodes of 8 vCPU / 16 GiB, then went to 3, then to 16 vCPU / 16 GiB.
  - **3 dedicated etcd nodes**, 8 vCPU / 16 GiB each.
- About 1000 worker VMs.
- API virtual IP served by HAProxy and Keepalived, as in the second round.
- Same kube-burner workload: create, read, patch and delete 2000 namespaces of Deployments, Services, ConfigMaps and Secrets, at 150 requests/s, and in two final runs at 300 requests/s. The settings from the second round (controller-manager tuning, a dedicated APF level for Cilium) were kept.

**Results: end of round 2 vs this round**

| | Round 2 final: 3 nodes, etcd on them, 8 vCPU | First run: 2 control-plane + 3 etcd, 8 vCPU | **Final: 3 control-plane (16 vCPU) + 3 etcd** |
|---|---|---|---|
| Client errors | 0 | 949 (943 Service create timeouts, retried) | **0** |
| Server errors (HTTP 5xx) | 1 | 6 | 2 (retried by the controllers) |
| Requests rejected by APF | 1,743 (bulk deletes) | 4,962 | **0** |
| Control-plane CPU at peak | 82–95 % | 95 % | **52–57 %** (64 % while patching) |
| etcd node CPU at peak | shared with the API server | ≤ 12 % | ≤ 19 % |
| Mean time to create one Service | 10–23 s | 20–28 s | 5–10 s |
| Pod Ready latency (99th percentile / max) | 5 / 6 s | 6.5 / 10 s | 5 / 7 s |
| Time until all 2000 Deployments were Ready | about 2 minutes | about 2.5 minutes | about 2 minutes |
| API server memory, busiest server | 8.1 GiB | 9.6 GiB | 7.5 GiB |
| Cleanup of 2000 namespaces | about 12 minutes | about 14 minutes | about 13 minutes |

The final setup is the first in the three rounds with no client errors, no APF rejections and spare control-plane CPU. At the same client rate it was not much faster, because the load-testing client set the pace. In two final runs at twice the rate (300 requests/s), it took in about 95–105 objects/s, against about 75/s on the old control plane at the same rate. The first had no errors; the second had a few dozen Service timeouts that were retried successfully. The intermediate runs had problems with etcd connections, load balance and APF. Each is explained below, with the fix that removed it.

**At twice the client rate (300 requests/s)**

| | Round 2: 3 nodes, etcd on them, 8 vCPU | **Final setup, run 1** | **Final setup, run 2** |
|---|---|---|---|
| Client errors | 728 (596 Service create timeouts, 132 patches) | **0** | 37 Service create timeouts, retried |
| Requests rejected by APF | 1,953 | **0** | **0** |
| Control-plane CPU at peak | 78–94 % | 65–71 % | 55–64 % |
| etcd node CPU at peak | shared with the API server | ≤ 24 % | ≤ 21 % |
| Services created per second, at peak | about 34 | about 37 | about 31 |
| Busiest API server's share of the Services | 40 % | 37 % | 44 % |
| Time until all creates were accepted | 109 s | 76 s | 85 s |
| Time until all 2000 Deployments were Ready | 1m55s | 1m51s | 1m51s |
| Pod Ready latency (99th percentile / max) | 5 / 5 s | 5 / 7 s | 5 / 6 s |
| Read / patch phases | 2m53s / 2m46s | 2m52s / 2m35s | 2m52s / 2m34s |

Everything except Service creation had plenty of margin at this rate. Read and patch took half as long as at 150 requests/s, because they are bound by the client rate. Service creation is still limited to about 40/s across three API servers, and how close a run comes to the timeout depends on how the client's connections are spread (finding 7).

**Key findings**

1. **Moving etcd to its own nodes doesn't help by itself: etcd was not the bottleneck, the API servers were.**
   - On dedicated nodes, etcd stayed under about 20 % CPU in every run, with disk syncs of 1–2 ms. Its memory stayed under 1.5 GiB.
   - With only 2 API servers, Service creation capacity fell by a third, to about 20 Services/s. In Kubernetes 1.36 each API server assigns ClusterIPs one at a time (see the second summary), so capacity grows with the number of API servers. 943 Service creates timed out. Going back to 3 API servers removed the timeouts.
   - **The etcd latency that the API servers see is mostly on the API server side.** Against the same idle etcd cluster, a lightly loaded API server saw 14 ms per write and a busy one 69 ms. The difference is CPU and scheduling inside the busy API server.

2. **Doubling the control-plane CPU (8 → 16 vCPU) removed the saturation.**
   - Each ClusterIP assignment dropped from 75–160 ms to about 60–85 ms. The allocators went from 90–100 % busy to 40–65 %.
   - Control-plane CPU at peak went from 92–98 % to 52–71 %. Each API server process still uses 6–9 cores at peak. The gain came mostly from the API server no longer competing with the controllers, kubelet and Cilium on 8 vCPU.
   - With the client sending about 37 Services/s, Services no longer queued for long, and none timed out.
   - **At twice the client rate (300 requests/s, about 73 Services/s sent), the first run was error-free.** The three API servers created about 37 Services/s at peak, against about 34/s on the 8 vCPU nodes, which had 596 timeouts at that rate. Their limit is about 40 Services/s (one ClusterIP every 70 ms per server). All pods were Ready in 1m51s, with the same pod latency as at 150 requests/s.
   - **But 300 requests/s is the edge, not a working rate.** Create requests time out after 34 s, and the longest wait in the first run was about 30 s. In the repeat, 37 Services timed out on the busiest server and were retried (finding 7). For error-free runs, use 200–250 requests/s.
   - At 150 requests/s, the remaining 5–10 s per Service create is mostly the time the request waits behind the client's own burst of requests, not server saturation.

3. **With dedicated etcd nodes, RKE2's built-in etcd proxy became the main source of errors. Pointing the API servers straight at the etcd members fixed it.**
   - By default, each RKE2 API server talks to etcd through a local proxy (`127.0.0.1:2379`) that sends all traffic to one etcd member at a time.
   - The proxy checks each member with a single HTTP request to the RKE2 process on the etcd node, with a **1-second timeout**. One slow reply marks the member as failed. The proxy then closes every API server connection to that member at once (about 100 streams).
   - These failovers happened in **every** run under load, against all three members. They happened even with control-plane CPU at 35 % and etcd nearly idle. Neither the timeout nor the threshold can be changed. In the worst run, 6 failovers in 42 s caused 111 server errors and 33 client errors.
   - **Fix:** set `--etcd-servers` on the API server to the three etcd members. The API server's own etcd client then spreads its connections across all members and handles failures per request. Server errors went from up to 112 per run to 2, and a broken connection now costs only the request on it.

4. **Rebalancing must include every DaemonSet with heavy API watches, not only the CNI. In RKE2 that includes the bundled ingress controller.**
   - RKE2 deploys its ingress controller (Traefik) as a DaemonSet on every node. With 1000 nodes, that is 1000 clients watching Services, EndpointSlices, Secrets, ConfigMaps and about 15 custom resources, the second-largest watch population after Cilium.
   - After API server restarts, we restarted Cilium and the node agents as recommended in the second summary, but not the ingress controller. Its pods kept their connections wherever they had landed, and the open connections were split 55k / 41k / 23k across the servers. The busiest server reached 92 % CPU, while the least busy one stayed at 44 %.
   - That server could not keep up with Service events, so it dropped about 16,000 slow Service watchers. They all reconnected at once. All 1000 ingress pods share one service account in `kube-system`, so they fell into one APF flow in the default `kube-system-service-accounts` FlowSchema, which rejected 997 requests with HTTP 429. This is the same trap Cilium hit in the second round.
   - **Fix, in three parts:**
     - restart the ingress DaemonSet as part of rebalancing;
     - give it its own APF FlowSchema and priority level, like Cilium;
     - raise the DaemonSet's `maxUnavailable` from the chart default of 1 pod to 10 %. With 1 pod at a time, a restart takes hours on 1000 nodes; with 10 %, a few minutes.
   - **Result:** connections within 3 % across the three servers, no dropped watchers and 0 rejections. The slowest pod became Ready in 7 s, against 16 s.
   - The same applies after a cluster rebuild or a mass rejoin of workers. In one run the kubelets were split 496 / 259 / 245 across the servers, and the slowest pods took 24 s to become Ready.
   - **The separate APF level paid off later.** Deleting 2000 Services at once made the 1000 ingress pods hit the API servers together: 260–470 of their requests were queued on each server. They waited in their own level and nothing was rejected. The Service deletion phase finished in 14 s, and no other client was slowed.

5. **Rebalancing has a cost: wait about an hour before heavy operations.**
   - Restarting about 2000 DaemonSet pods creates about 30,000 Events, which are kept for 1 hour. It also rewrites thousands of Nodes, Pods, Leases and Cilium objects.
   - The etcd database file grew from 98 MB to 947 MiB within an hour of a rebalance. API server memory went up by about 3 GiB.
   - **Order that worked:** restart the control plane, rebalance, wait 1 hour (or delete the Events), defragment etcd, then start the heavy work. Starting 15 minutes after the rebalance cost only a few seconds per phase, so the wait helps but isn't critical.

6. **One issue is still open: short network stalls between the API servers and etcd.**
   - About once or twice per run, one API server → etcd connection got no TCP acknowledgment for about 10 s, and the request on it failed with `read: connection timed out`.
   - It has happened from two of the three control-plane nodes, to all three etcd members, and only at busy moments. etcd was idle each time and logged nothing.
   - It did not happen in the two runs at 300 requests/s, which were shorter. So it doesn't simply get worse with load.
   - We suspect the virtualized network path under load. We haven't confirmed it. With direct etcd connections, each stall costs one request, which the controllers retry. Behind RKE2's proxy, the same kind of hiccup would have caused a failover storm, as in finding 3.
   - The lost client connection from the second summary happened once in this round. The likely cause is the API server's `goaway-chance` closing a connection while the 1-vCPU test client was busy opening hundreds of TLS connections at the start of a job. It did not happen in the last four runs. Clients that retry are not affected.

7. **The load balancer spreads connections, not requests, so one client can be limited to one API server's capacity.**
   - HAProxy (like most layer-4 load balancers) picks a server per TCP connection. Clients such as kube-burner, CI pipelines or GitOps controllers send all their requests over a few long-lived HTTP/2 connections. Which servers those connections land on decides each server's share.
   - In the two runs at 300 requests/s, the busiest API server received 37 % and then 44 % of the Services. Each API server can assign at most about 15 ClusterIPs/s. At 44 %, that server's queue passed the 34 s create timeout for the last few seconds of the burst, while the other two had spare capacity. Overall creation was slower (31 Services/s against 37/s).
   - Admin clients (`system:masters`) are exempt from API Priority and Fairness, so nothing queues or spreads their load. The API server just runs everything it receives.
   - **Implication:** for bursts of Service creation from one client, plan on one API server's capacity (about 15 Services/s at 16 vCPU), not the cluster total of about 40/s.

**Recommendations**

These add to the recommendations of the first two summaries.

- **Size the API servers before splitting out etcd.** For about 1000 nodes with high churn, use at least 3 API servers with 16 vCPU and 16 GiB each. etcd on dedicated nodes needs little: under 25 % of 8 vCPU even at 300 requests/s, and under 1.5 GiB of memory, so 4 vCPU / 8 GiB is probably enough (not tested). Dedicated etcd nodes are still useful to isolate etcd from API server CPU spikes. They don't replace a bigger control plane.
- **With dedicated etcd nodes, bypass RKE2's etcd proxy.** In the RKE2 server config of the control-plane nodes:
  ```yaml
  kube-apiserver-arg:
    - etcd-servers=https://<etcd-1>:2379,https://<etcd-2>:2379,https://<etcd-3>:2379
  ```
  The API server's existing etcd client certificate works with every member. Change it one node at a time, and rebalance afterwards.
- **Rebalance every large DaemonSet after control-plane restarts:** the CNI agents, the ingress controller and the node agents.
  - Set `maxUnavailable` to about 10 % on those DaemonSets so that a restart takes minutes.
  - For the RKE2 ingress controller, set it with a `HelmChartConfig` on `rke2-traefik`: `updateStrategy.rollingUpdate.maxUnavailable: 10%`.
  - Before heavy operations, check that the API servers hold similar numbers of goroutines (within about 15 %). Wait about an hour for the rebalance churn to clear, then defragment etcd.
- **Give every large kube-system DaemonSet its own API Priority and Fairness level**, not just the CNI: the ingress controller too, and any agent that runs on every node and watches widely.
  - The default `kube-system-service-accounts` FlowSchema puts all of them in a single flow.
  - Use `distinguisherMethod: ByUser` and a precedence below 900.
  - Keep the shuffle-sharding settings within the API server's limit: with 64 queues, a `handSize` of 8 is accepted; 16 is rejected.
- **Plan Service creation bursts per API server, not per cluster** (until Kubernetes 1.38, which removes the one-at-a-time ClusterIP assignment).
  - Each API server assigns about 15 ClusterIPs/s at 16 vCPU. A Service create that waits more than 34 s fails with HTTP 504 and must be retried.
  - A single client with a few connections may get only one server's capacity (finding 7). Spread large bursts over time, or across clients.
  - Where a ClusterIP isn't needed, use headless Services (`clusterIP: None`): they skip the assignment entirely.
- **Disable bundled components you don't use.** On a 1000-node cluster, an unused ingress controller is 1000 extra watchers. In RKE2: `disable: [rke2-traefik]` in the server config.
- **Watch the API server logs for etcd connection errors** (`read: connection timed out`, `error reading from server`). A few per day are retried and harmless. If there are more, check the network between the control-plane and etcd nodes: retransmissions, round-trip time, and VM placement on the hypervisor hosts.

**Caveat:** as before, these results come from one virtualized lab environment. The exact limits depend on hardware, the CNI, the Kubernetes version and the shape of the workload. Run a load test that matches your own workload before going to production.
