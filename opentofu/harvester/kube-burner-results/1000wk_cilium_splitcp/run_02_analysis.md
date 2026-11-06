# Split control plane, run 02 — api-intensive, 2000 iterations, QPS 150 / burst 200

Results: `results-api-intensive-20261103T150609Z-LHK3WN`. Benchmark settings are the same as [run 01](./run_01_analysis.md) and [haproxy run 15](../1000wk_cilium_haproxy/run_15_analysis.md): `ITERATIONS=2000 QPS=150 BURST=200 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`. The change is a third control-plane node:

| | haproxy run 15 | split CP run 01 | **split CP run 02** |
|---|---|---|---|
| API server + KCM + scheduler nodes | 3, etcd stacked | 2, no etcd | **3**, no etcd (cp-03 added the same day) |
| etcd nodes | stacked | 3 dedicated | 3 dedicated |
| Node size | 8 vCPU / 16 GiB | 8 vCPU / 16 GiB | 8 vCPU / 16 GiB |

Cluster state at start:
- **Unbalanced API servers.** cp-03 had joined at 13:27 and still had half the load of the others:

  | | cp-01 | cp-02 | cp-03 |
  |---|---|---|---|
  | Goroutines | 46.7k | 49.1k | **21.7k** |
  | API server RSS | 7.8 GiB | 8.7 GiB | 4.4 GiB |
  | Node memory | 76 % | 73 % | 39 % |

  The long-lived watches (kubelets, Cilium agents) stayed on cp-01/02.
- **etcd:** defragmented before the run (147 MiB file). etcd-01 was the leader for the whole run, with no leader changes.
- **KCM leader: cp-01** for the whole run.
- **Host placement on Harvester:**

  | Host | VMs |
  |---|---|
  | u10 | cp-01, etcd-02 |
  | u2 | cp-03, etcd-01 |
  | u15 | cp-02 |
  | u11 | etcd-03 |

## Verdict

**The third API server removed almost all the failures: 18 kube-burner errors against 949, and only one timeout. Object creation finished in 76 s against 140 s, and the job took 2m03s against 2m38s.** Pods were a little faster than in run 15.

Two problems remain:
- **The load was unbalanced.** cp-03 handled 60 % of the Service creates at 19 ms per allocation, while cp-01/02 were back at 95–98 % CPU.
- **An etcd connection reset on cp-02 again caused 17 EOF errors.** The cause is now confirmed in the logs: RKE2's client-side etcd load balancer (Finding 3).

Namespace cleanup still takes 14 min. That is the namespace controller, not the topology.

## Comparison

| | haproxy run 15 (3 stacked CP) | split CP run 01 (2 CP) | **split CP run 02 (3 CP)** |
|---|---|---|---|
| kube-burner errors | 0 | 949 | **18** (17 EOF, 1 timeout) |
| Service create timeouts | 0 | 943 | **1** |
| Creation done after trigger | — | 140 s | **76 s** |
| Job duration | — | 2m38s | **2m03s** |
| Combined allocation rate, peak window | ~30/s | ~20/s | **~27/s** (4.0 / 6.2 / 16.8) |
| Mean ClusterIP allocation, creation | 86 / 157 / 87 ms | 94 / 101 ms | 178 / 109 / **19** ms |
| Mean Service POST, peak window | 10–22 s | 28 / 20 s | 17.3 / 11.9 / **0.05** s |
| API server → etcd create latency, peak window | 67–74 ms | 66 / 92 ms | 86 / 83 / **14** ms |
| Peak CP node CPU (creation) | 86 / 95 / 82 % | 95 / 95 % | 98 / 95 / 55 % |
| Peak etcd node CPU | (stacked) | ≤ 12 % | ≤ 16 % |
| Pod Ready p99 / max / avg | 5 / 6 / 3.0 s | 6.5 / 10 / 3.7 s | **5 / 6 / 2.8 s** |
| PodScheduled p99 / Initialized p99 | 1.6 s / 1 s | 2.1 s / 2 s | 1.9 s / 2 s |
| Read / patch | 5m39s / 2m58s | 5m39s / 3m01s | 5m40s / 3m12s |
| remove-deployments / services / configs | 18 / 22 / 40 s | 20 / 24 / 51 s | 22 / 23 / 41 s |
| APF rejections (during creation) | 1,743 (0) | 4,962 (673) | **3,298 (0)** |
| API server peak RSS | 7.6 / 8.1 / 7.8 GiB | 8.6 / 9.6 GiB | 8.5 / 8.8 / 4.8 GiB |
| Namespace cleanup | 11m54s | 14m00s | 14m03s |

## Findings

### 1. The third API server took most of the Service creates, and the queue never reached the 60 s timeout

kube-burner sent iterations 200 → 1,800 between 15:06:55 and 15:07:38. That is ~37 Services/s, as in run 01.

Creation window 15:06:27 → 15:08:00:

| Server | Service POSTs | Mean POST | Mean allocation | Allocator busy |
|---|---|---|---|---|
| cp-01 (KCM leader) | 295 | 13.9 s | 178 ms | 59 % |
| cp-02 | 507 | 9.2 s | 109 ms | 60 % |
| cp-03 | **1,201** | **0.05 s** | **19 ms** | 24 % |

- HAProxy `leastconn` sent new kube-burner connections to cp-03 because it held the fewest connections. That happened to be the right choice: cp-03 was the only server with spare CPU.
- 2,003 allocations served 2,000 Services, against 2,759 in run 01, so there were almost no retries.
- **The only timeout** (api-intensive-241, a 504 on cp-01 at 15:07:38) was a retry of a create that had failed with EOF. It landed on the busiest server.
- On cp-01/02, mean POST time was still 9–17 s. With a balanced cluster, all three servers would sit around 30–40 % allocator busy, not 74 / 74 / 34 %.

### 2. API server → etcd latency follows API server CPU, not etcd

In the peak window (15:07:09 → 15:08:00), all three servers talked to the same etcd cluster:

| | cp-01 | cp-02 | cp-03 |
|---|---|---|---|
| Process CPU | 6.6 cores | 6.6 cores | 3.6 cores |
| Node CPU | 98 % | 95 % | 55 % |
| etcd create latency (API server view) | 86 ms | 83 ms | **14 ms** |
| Mean ClusterIP allocation | 178 ms | 109 ms | 19 ms |

Meanwhile, on the etcd side:
- WAL fsync was 1.1–2.2 ms and backend commit 2–5.8 ms.
- Peer RTT was 2–4.8 ms.
- Node CPU was ≤ 16 % and process CPU ≤ 0.9 cores.

So the 85 ms is time spent in a CPU-starved API server process (gRPC, TLS, serialization, scheduling), not in etcd. This confirms the run 01 conclusion: **in this topology, API server CPU is the resource that matters. etcd is oversized.**

### 3. The EOF errors come from RKE2's etcd load balancer failing over under load (confirmed)

kube-burner got 17 `rpc error: code = Unavailable desc = error reading from server: EOF` / `unexpected EOF` errors at 15:06:57–15:07:03 (Secrets, ConfigMaps, 9 Deployments, 2 Services), all on cp-02. On the server side there were 18 etcd create errors, 4 etcd update errors and 22 500s on cp-02. All were retried successfully.

On a control-plane-only RKE2 server, kube-apiserver runs with `--etcd-servers=https://127.0.0.1:2379`. That address is the **rke2 process's built-in TCP load balancer**, which forwards to one etcd member and fails over on health-check failure. The cp-02 journal shows:

```
15:06:57 Server 192.168.70.173:2379@ACTIVE->FAILED from failed health check
15:06:57 Closing 107 connections to load balancer server 192.168.70.173:2379@FAILED
15:06:57 Server 192.168.68.41:2379@HEALTHY->ACTIVE from successful dial
15:07:02 Server 192.168.70.173:2379@FAILED->RECOVERING from successful health check
```

The apiserver log shows the in-flight `KV/Txn` calls failing with EOF in the same millisecond. etcd-01 itself was fine: it was the leader, had no leader change and ran at low CPU. The health check failed because the probe did not complete in time on a CPU-saturated node (cp-02 was at 95 %). The probe recovered 5 s later. Each such failover cuts **every** API server → etcd stream at once.

The same events appear throughout the day on all three CP nodes:
- **cp-01:** 15:07:06, 15:08:03, 15:17:31, 15:19:25 (during this run), plus several in the morning. Most of these were on a non-active (`HEALTHY*`) server, so no connections were closed.
- **cp-02:** 11:16:28 during run 01 (closed 103 connections), plus 11:25–11:27 and 12:11.
- **cp-03:** 15:19:01 during the removes (closed 103 connections, no kube-burner errors because the removes were idempotent).

The problem gets worse when the API server node is CPU-saturated, which is the case for cp-01/02 here. With stacked etcd, each API server talks to its local etcd member directly, so this failure mode did not exist in the haproxy series.

### 4. APF, KCM, etcd and memory

- **APF:** 3,298 rejections, all `queue-full` in `workload-high` / `kube-system-service-accounts`. They all happened during the remove jobs (15:19–15:20): 2,553 on cp-01, 743 on cp-02, and none on cp-03 apart from 3 WATCH 429s. There were **none during creation** (673 in run 01).
  - Max executing exempt was 299 on cp-01 at 15:19.
  - Max mutating inflight was 498 on cp-01, 131 on cp-02 and 10 on cp-03.
- **KCM (cp-01):**
  - 6,041 PUT 409 conflicts over the run, 1,439 of them during creation.
  - Rate-limiter wait means: PUT 59 ms, POST 38 ms.
  - Deployment queue peaks: 1,544 at 15:08:06 and 1,990 at 15:16:31 (patch).
  - endpoint_slice queue peaked at 1,048, and GC `attempt_to_delete` at 4,583 (15:19).
  - The namespace queue stayed at about 1,975 for the whole 14-minute cleanup. Namespace deletion speed is limited by the namespace controller, whatever the number of API servers.
- **etcd:**
  - etcd-01 +2 failed proposals (15:07:12). etcd-03 +96 slow applies and up to 17 pending proposals.
  - **etcd-03 serves ~1,000 ranges/s at steady state, against ~155 on the others.** One heavy client is pinned to it: each CP's RKE2 load balancer uses one active member at a time.
  - The DB file grew from 147 to 666 MiB, with 171 MiB in use. Defragmenting between runs keeps it small.
- **Memory:** API server RSS peaked at 8.5 / 8.8 / 4.8 GiB. cp-01/02 would reach about 6 GiB each if the watches were spread over three servers.
- **Cilium / kubelet** on the sampled nodes: only routine 403/404s.

## Recommendations

1. **Rebalance before each run.**
   - Run `kube-burner/rebalance.sh` (or roll the Cilium agents and kubelets) after adding a CP node or restarting one.
   - Before starting a benchmark, check that API server goroutines are within about 10 % across cp-01/02/03.
   - Rerun run 02 balanced. We expect 0 errors and the CP nodes at around 70 % CPU.
2. **Fix the etcd EOFs on the split topology.** Options, roughly by effort:
   - Give the control-plane nodes more CPU (12–16 vCPU) so that neither the API server nor the RKE2 health probe gets starved. That is where the CPU is needed anyway (Finding 2).
   - Bypass the RKE2 load balancer: point kube-apiserver at all three etcd members with `kube-apiserver-arg: etcd-servers=https://<etcd-01>:2379,https://<etcd-02>:2379,https://<etcd-03>:2379`. The etcd client then balances and retries per request instead of losing all streams at once. This also spreads reads across members (etcd-03 is currently overloaded). It needs testing on RKE2, which manages the flag and the client certificates.
3. **Downsize etcd.** etcd stayed at ≤ 16 % CPU and ≤ 1.1 GiB RSS. 4 vCPU / 8 GiB is enough, and the freed capacity can go to the control plane.
4. **Spread the VMs across hosts.** u10 (cp-01 + etcd-02) and u2 (cp-03 + etcd-01) each host a CP, an etcd member and about 61 workers. Use anti-affinity, or pin CP and etcd to dedicated Harvester hosts.
5. **Defragment etcd before every run** to keep runs comparable (the DB file grew 147 → 666 MiB).
6. **Namespace cleanup (14 min)** does not depend on the CP topology. To shorten it, raise `concurrent-namespace-syncs` on KCM (default 10).
