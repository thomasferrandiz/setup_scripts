# Split control plane, run 01 — api-intensive, 2000 iterations, QPS 150 / burst 200

Results: `results-api-intensive-20261103T111351Z-3bh4Ct`. Benchmark settings are the same as [haproxy run 15](../1000wk_cilium_haproxy/run_15_analysis.md): `ITERATIONS=2000 QPS=150 BURST=200 PRE_CREATE_NAMESPACES=true`, all metrics `required`, `NODE_SAMPLE_COUNT=5`. The change is the topology:

| | haproxy run 15 | **split CP run 01** |
|---|---|---|
| API server + KCM + scheduler nodes | 3 (8 vCPU / 16 GiB), etcd on the same nodes | **2** (8 vCPU / 16 GiB), no etcd |
| etcd nodes | stacked | **3 dedicated** (8 vCPU / 16 GiB) |
| Workers | ~1000 | 1000 (all Ready) |
| Kubernetes | 1.36 | v1.36.5+rke2r1 |

Cluster state at start:
- **Fairly balanced:** goroutines 53.5k on cp-01 and 62.3k on cp-02 (116k in total, about the same as run 15's 118k across three servers). API server RSS 5.4 / 6.0 GiB.
- **etcd:** 464 MiB file, 126 MiB in use. etcd-01 was the leader for the whole run. No leader change, and no new failed proposals except 2 on etcd-02 and 10 on etcd-03.
- **KCM leader: cp-01** for the whole run. The KCM and Cilium APF tuning from the haproxy series is in place: the deployment queue drained in under a minute, and there is a `cilium` priority level.

## Verdict

**Moving etcd to its own nodes did not help, because etcd was not the bottleneck. Going from 3 API servers to 2 cut Service creation capacity by a third, so the run had 943 Service create timeouts (0 in run 15). kube-burner's retries created every object. Pods were nearly as fast as in run 15.**

- **Worse than run 15:**
  - **943 Service create timeouts** (0) on 701 distinct Services, all retried successfully (Finding 1).
  - **6 other 5xx errors from the API server losing its etcd connection** (`rpc error: code = Unavailable desc = error reading from server: EOF`). This is new with the split topology (Finding 3).
  - Both control-plane nodes were at **95 % CPU** during creation (86 / 95 / 82 % in run 15), while the etcd nodes stayed at **≤ 12 %**.
  - APF rejections: **4,962** (1,743), including 673 during creation (none in run 15).
  - Namespace cleanup took **14m00s** (11m54s). remove-* jobs: 20 / 24 / 51 s (18 / 22 / 40 s).
  - API server peak RSS: **8.6 / 9.6 GiB** (7.6–8.1 GiB). Each server now holds half of the watches, not a third.
- **Same as run 15:**
  - Pod Ready p99 **6.5 s**, max 10 s, average 3.7 s (5 / 6 / 3.0 s).
  - Read **5m39s** (5m39s), patch **3m01s** (2m58s).
  - The `cilium` priority level rejected nothing.

## Comparison

| | haproxy run 15 (3 stacked CP) | **split CP run 01 (2 CP + 3 etcd)** |
|---|---|---|
| kube-burner errors | 0 | **949** (943 timeouts, 6 EOF / IP-allocation 500s) |
| Service create timeouts | 0 | **943** |
| ClusterIP allocation, peak window | 86 / 157 / 87 ms | 94 / 101 ms |
| Combined allocation rate, peak window | ~30 Services/s | **~20 Services/s** |
| Mean Service POST, peak window | 10–22 s | **28 s (cp-01) / 20 s (cp-02)** |
| API server → etcd create latency, peak window | 67–74 ms | 66 ms (cp-01) / 92 ms (cp-02) |
| etcd backend commit / WAL fsync | 9–14 ms / 3–5 ms | **4–5 ms / ~2 ms** |
| Peak control-plane node CPU (creation) | 86 / 95 / 82 % | **95 / 95 %** |
| Peak etcd node CPU | (stacked) | 10 / 11 / 9 % |
| Pod Ready p99 / max / avg | 5 / 6 / 3.0 s | 6.5 / 10 / 3.7 s |
| PodScheduled p99 / Initialized p99 | 1.6 s / 1 s | 2.1 s / 2 s |
| Read / patch | 5m39s / 2m58s | 5m39s / 3m01s |
| remove-deployments / services / configs | 18 / 22 / 40 s | 20 / 24 / 51 s |
| APF rejections | 1,743 | 4,962 |
| API server peak RSS | 7.6 / 8.1 / 7.8 GiB | 8.6 / 9.6 GiB |
| Namespace cleanup | 11m54s | 14m00s |

## Findings

### 1. Two API servers can allocate only ~20 ClusterIPs/s, so Services queued past the 60 s timeout

As in run 15, kube-burner sent iterations 200 → 1,800 in 43 s (11:14:44 → 11:15:27), so about **37 Services/s**.

Each API server allocates ClusterIPs one at a time (haproxy run 15, Finding 1). In the busiest window (about 11:14:52 → 11:15:50):

| Server | Allocations | Rate | Mean allocation | Allocator busy | Mean Service POST |
|---|---|---|---|---|---|
| cp-01 (KCM leader) | 596 | 10.6/s | 94 ms | **100 %** | **28 s** |
| cp-02 | 560 | 9.8/s | 101 ms | **99 %** | 20 s |

- The two servers together allocated about **20 Services/s**, against 37/s sent. The queue grew by about 17/s, so after about 40 s, new Services were waiting more than 60 s. In run 15, three servers reached about 30/s and the longest wait was about 40 s.
- Allocation time did not improve: 94–101 ms here, against 86–87 ms on run 15's non-leader servers. Each allocation is an etcd write, and the API server's etcd latency is set by its own CPU (Finding 2).
- The timeouts started at 11:15:3x, 60 s after the first queued creates, and stopped at 11:16:2x. kube-burner retried each one: 2,759 ClusterIP allocations served 2,000 Services. 19 retries got `already exists`, because the first attempt had in fact succeeded after the client gave up.
- **The timeouts were almost all on cp-01:** 481 504s and 701 failed etcd creates (requests whose context had expired before the Service was stored). That is exactly the 701 distinct Services that timed out. cp-01 received more Service POSTs (1,706 against 1,055 including retries), and it is also the KCM leader. As in run 15, HAProxy `leastconn` does not send fewer creates to the slower server.

### 2. etcd on dedicated nodes was idle, and the API servers became the bottleneck

- **etcd was very healthy:** 0.4–0.7 cores per member, WAL fsync about 2 ms, backend commit 4–5 ms, peer RTT 2–4 ms, up to 680 puts/s and 1,100–1,500 ranges/s. Its node CPU never went above 12 %, and memory used was about 1.5 GiB.
- **The API servers saw no benefit.** Their etcd create latency was 66 / 92 ms during creation, the same as in run 15 (67–74 ms), even though etcd itself committed 2–3 times faster. The extra time is spent inside the API server (CPU scheduling, encoding, the network hop), not in etcd.
- **The API servers were CPU bound:** 6.4 and 6.3 cores each (95 % node CPU), with up to 639 / 352 mutating requests in flight. kube-burner's own requests run in the `exempt` APF level (up to 583 executing on cp-01), so APF doesn't queue them; they pile up inside the server instead.
- In total, the API servers had 16 vCPU instead of 24, while the 24 vCPU of the etcd nodes were mostly unused.

### 3. New: the API server lost its etcd connection twice

- At **11:15:02–03** and again at **11:16:09–17**, requests on **cp-02** failed with `rpc error: code = Unavailable desc = error reading from server: EOF`. That is the API server's gRPC connection to an etcd member being closed.
- On the server side: 24 etcd create and 35 update errors on cp-02, 43 500s (24 POST, 16 PUT, 3 PATCH), and 2 ClusterIP allocation errors (`failed to allocate IP: ... EOF`). kube-burner saw 6 of them (Secret, Deployment and Service creates) and retried them.
- No etcd restart and no leader change. etcd-01 (leader) had 22 pending proposals and +14 slow applies around 11:15. etcd-03 had +10 failed proposals between 11:15:50 and 11:16:38.
- This could not happen with stacked etcd, where the API server talks to its local member. The metrics can't show which member closed the connection or why. etcd and API server logs from those times are needed.

### 4. APF, KCM, Cilium and memory

- **APF:** all 4,962 rejections are `queue-full` in `workload-high` (`kube-system-service-accounts`), mostly WATCH re-establishments: 673 during creation (11:14–11:16) and 4,289 during the remove jobs (11:26–11:27). Run 15 had none during creation. With two servers, each holds about half of the kube-system watches, so their bursts are bigger. The `cilium` level rejected nothing.
- **KCM (cp-01):** deployment queue peaked at 1,275 (11:15:50) and was empty at the next sample. Client-side rate-limiter waits stayed below 0.1 s. KCM was not the limit.
- **Memory:** API server RSS peaked at 8.6 GiB (cp-01) and 9.6 GiB (cp-02) at 11:27–11:28 during the remove jobs. Node memory reached 71 / 74 %. This is the highest RSS so far without a restart.
- **etcd size:** the file grew from 464 to 656 MiB with churn (no compaction or defragmentation during the run).
- `kubelet-errors.log` only shows one unreachable kubelet metrics endpoint (bench-wk-601) at 11:14:12, before the run started.

## Recommendations

1. **Don't reduce the number of API servers to make room for dedicated etcd nodes.** At this scale, the API servers, not etcd, are the limit. Each API server allocates ClusterIPs one at a time, so Service creation capacity scales with the number of API servers. If you keep etcd separate, use at least **3 control-plane nodes + 3 etcd nodes**, or give the control-plane nodes more vCPU.
2. **Downsize the etcd nodes.** They peaked at under 1 core and 1.6 GiB. 2–4 vCPU and 8 GiB each would be enough for this workload, and fast disks matter more than CPU. Use the freed resources for the control plane.
3. **To measure this topology's error-free limit, re-run with `QPS=100 BURST=200`** (about 25 Services/s, just above the ~20/s measured here), or with QPS 75. Compare only runs with the same QPS.
4. **Investigate the etcd connection drops (Finding 3):** collect `journalctl -u rke2-server` and the etcd pod logs on all etcd nodes around 11:15:02 and 11:16:09. Look for `transport is closing`, `stream error` or `keepalive` messages, and check whether a load balancer or firewall sits between the API servers and etcd.
5. **Defragment etcd between runs** (464 → 656 MiB file in this run), as recommended in the haproxy series.
6. Kubernetes 1.38 (concurrent ClusterIP allocation, kubernetes/kubernetes#142758) should remove the per-server Service limit and make the split topology more attractive.
