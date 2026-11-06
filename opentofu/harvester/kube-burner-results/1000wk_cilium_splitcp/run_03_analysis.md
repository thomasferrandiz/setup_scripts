# Split control plane, run 03 — api-intensive, 2000 iterations, QPS 150 / burst 200

Results: `results-api-intensive-20261103T164333Z-bBgPEx`. The settings and topology are the same as [run 02](./run_02_analysis.md): 3 control-plane nodes (API server, KCM and scheduler) and 3 dedicated etcd nodes, all 8 vCPU / 16 GiB. `ITERATIONS=2000 QPS=150 BURST=200 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`.

Cluster state at start:
- **API servers more balanced than in run 02, but cp-03 still lighter:**

  | | cp-01 | cp-02 | cp-03 |
  |---|---|---|---|
  | Goroutines | 45.6k (run 02: 46.7k) | 44.3k (49.1k) | **28.3k** (21.7k) |
  | API server RSS | 7.6 GiB (7.8) | 7.7 GiB (8.7) | 6.1 GiB (4.4) |
  | Node memory | 64 % (76) | 60 % (73) | 49 % (39) |

- **etcd:** defragmented before the run (129 MiB). etcd-01 was the leader for the whole run, with no leader changes.
- **KCM leader: cp-01** for the whole run.
- **etcd connection:** all three API servers still use `--etcd-servers=https://127.0.0.1:2379`, the RKE2 etcd load balancer.

## Verdict

**This is the first clean run of the series for kube-burner: 0 kube-burner errors and 0 Service timeouts.** Pod Ready p99 was 4 s, the best so far. There was no 5xx during creation. The only server-side errors were 12 controller PUT 500s on cp-03 during remove-services (Finding 3).

- The control-plane CPU was spread better than in run 02: 91 / 80 / 62 % at peak, against 98 / 95 / 55 %.
- **cp-01 is still the bottleneck.** It is the KCM leader and also received a quarter of kube-burner's Service creates. It took 17.5 s per Service POST on average, against 0.12 s on cp-03.
- **The RKE2 etcd load balancer failed health checks again.** This time the failures were on standby members, or during the remove jobs, so nothing failed. The problem is still there (Finding 3).
- Throughput was the same as in run 02. The 14-minute namespace cleanup is unchanged.

## Comparison

| | haproxy run 15 (3 stacked CP) | split run 01 (2 CP) | split run 02 (3 CP) | **split run 03 (3 CP)** |
|---|---|---|---|---|
| kube-burner errors | 0 | 949 | 18 | **0** |
| Service create timeouts | 0 | 943 | 1 | **0** |
| API server 5xx / etcd client errors | 0 / 0 | 43 / 59 | 22 / 22 | **12 / 12** (removes only) |
| Iteration 1,800 / all creates done after trigger | — | — / 140 s | 67 s / 76 s | 69 s / 88 s |
| Job duration | — | 2m38s | 2m03s | 2m02s |
| Service creates per server | — | 1,706 / 1,055 (incl. retries) | 295 / 507 / 1,201 | 484 / 410 / 1,106 |
| Combined allocation rate, peak window | ~30/s | ~20/s | ~27/s | ~24/s (6.2 / 4.9 / 12.8) |
| Mean ClusterIP allocation, creation | 86 / 157 / 87 ms | 94 / 101 ms | 178 / 109 / 19 ms | 134 / 83 / 23 ms |
| Mean Service POST, creation | 10–22 s | 28 / 20 s | 13.9 / 9.2 / 0.05 s | **17.5** / 5.5 / 0.12 s |
| API server → etcd create latency, creation | 67–74 ms | 66 / 92 ms | 86 / 83 / 14 ms | 56 / 38 / 15 ms |
| Peak CP node CPU (creation) | 86 / 95 / 82 % | 95 / 95 % | 98 / 95 / 55 % | **91 / 80 / 62 %** |
| Peak etcd node CPU | (stacked) | ≤ 12 % | ≤ 16 % | ≤ 18 % |
| Pod Ready p99 / max / avg | 5 / 6 / 3.0 s | 6.5 / 10 / 3.7 s | 5 / 6 / 2.8 s | **4 / 5 / 2.6 s** |
| PodScheduled p99 / Initialized p99 | 1.6 s / 1 s | 2.1 s / 2 s | 1.9 s / 2 s | **1.3 s / 1 s** |
| Read / patch | 5m39s / 2m58s | 5m39s / 3m01s | 5m40s / 3m12s | 5m40s / 3m07s |
| remove-deployments / services / configs | 18 / 22 / 40 s | 20 / 24 / 51 s | 22 / 23 / 41 s | 25 / 24 / 41 s |
| APF rejections (during creation) | 1,743 (0) | 4,962 (673) | 3,298 (0) | **2,011** (77 WATCH) |
| API server peak RSS | 7.6 / 8.1 / 7.8 GiB | 8.6 / 9.6 GiB | 8.5 / 8.8 / 4.8 GiB | 8.4 / 8.6 / 6.8 GiB |
| Namespace cleanup | 11m54s | 14m00s | 14m03s | 13m55s |

Note: under load, the metrics scraper only got a sample every 40–60 s (16:43:51 → 16:44:33 → 16:45:32). The "creation" window is therefore 16:43:51 → 16:45:32, and the "peak" window is 16:44:33 → 16:45:32.

## Findings

### 1. No errors, but cp-01 still serves its Services 150 times slower than cp-03

kube-burner sent iterations 200 → 1,800 between 16:44:20 and 16:45:03. That is ~37 Services/s, as in runs 01 and 02.

Creation window (16:43:51 → 16:45:32):

| Server | Service POSTs | Mean POST | Mean allocation | Allocator busy | etcd create | Process CPU | All POSTs |
|---|---|---|---|---|---|---|---|
| cp-01 (KCM leader) | 484 | **17.5 s** | 134 ms | 64 % (82 % at peak) | 56 ms | 6.0 cores | **17,475** |
| cp-02 | 410 | 5.5 s | 83 ms | 34 % | 38 ms | 5.6 cores | 11,163 |
| cp-03 | 1,106 | 0.12 s | 23 ms | 25 % | 15 ms | 4.1 cores | 9,757 |

- **cp-01 receives about 60 % more POSTs than the other servers.** The KCM leader sends all its ReplicaSet, Pod, EndpointSlice and Event writes to its local API server, and it also issues 47k PUTs (6,040 of them 409 conflicts). On top of that, HAProxy `leastconn` still sends it a quarter of kube-burner's Service creates. Its ClusterIP queue reached 20 s mean POST in the peak window. That is a third of the 60 s timeout.
- cp-03 is still lighter (28k goroutines against 45k), so `leastconn` sent it 55 % of the Services. It processed them in 23 ms.
- The last Services were queued on cp-01. That explains why creation took 19 s after iteration 1,800 to finish, against 9 s in run 02. The job duration was the same (2m02s).
- In the peak window, the combined allocation rate was about 24/s against 37/s sent. The headroom is small: a slightly busier cp-01, or a run at a higher QPS, would bring the run 01 timeouts back.

### 2. API server → etcd latency still follows API server CPU

The three servers write to the same etcd cluster. Their etcd create latency was 56 / 38 / 15 ms, in the same order as their CPU load. On the etcd side, WAL fsync stayed at ≤ 2.3 ms, backend commit at ≤ 6.6 ms and peer RTT at ≤ 3.6 ms. etcd process CPU stayed at ≤ 1.1 cores and node CPU at ≤ 18 %. This is the same pattern as in runs 01 and 02: in this topology, the scarce resource is control-plane CPU, and etcd has capacity to spare.

### 3. The RKE2 etcd load balancer is still failing health checks, and this run was lucky

The journal of each CP node (`rke2-server`) during the run:

```
cp-01  16:44:34  192.168.65.189(etcd-02):2379@HEALTHY->FAILED   (standby, nothing closed)
cp-01  16:45:00  192.168.70.173(etcd-01):2379@HEALTHY*->FAILED  (standby, nothing closed)
cp-02  16:44:37  192.168.65.189(etcd-02):2379@HEALTHY->FAILED   (standby, nothing closed)
cp-03  16:56:19  192.168.68.41(etcd-03):2379@ACTIVE->FAILED
cp-03  16:56:19  Closing 105 connections to load balancer server 192.168.68.41:2379@FAILED
```

- **During creation**, the health checks failed only on standby members, so no API server → etcd connections were cut. In run 02, the same kind of event hit cp-02's **active** member and produced 17 EOF errors.
- **During remove-services**, cp-03 dropped all 105 connections to etcd-03 and switched to etcd-02. The in-flight writes failed: 12 etcd update errors and 12 PUT 500s on cp-03 at 16:56:36. These were controller status updates, which retry on their own, so kube-burner saw nothing. cp-03 was at 53 % CPU at the time. (Correction: an earlier version of this analysis said no request failed. These counter series only appeared after the failover, and the first-to-last delta did not count them.)
- cp-01 and cp-02 failed the check against **the same member (etcd-02) within 3 seconds** of each other. cp-03's failover also happened at moderate CPU. Together, this weakens the run 02 explanation of a "CPU-starved client". The health check is at least partly timing out on the etcd side or on the path to it. etcd-02 had no slow applies at 16:44. etcd-03 had +168 slow applies over the run (+54 on etcd-02 at 16:56:36), and up to 18 pending proposals.
- **etcd-03 is the read-heavy member again:** up to 3,007 ranges/s, against ≤ 1,015 on the others. Each RKE2 load balancer sends all its traffic to a single member, so reads are not spread.

Whether a given run sees EOFs depends on whether a check fails on an **active** member while writes are in flight. The underlying risk has not changed.

### 4. APF, KCM, etcd and memory

- **APF:** 2,011 rejections, all `queue-full` in `workload-high` / `kube-system-service-accounts`, and all on WATCH.
  - 77 were on cp-01 at the end of creation (16:45:32). These are controller re-watches, not kube-burner requests.
  - The rest came during the removes (16:56–16:57): 1,056 on cp-01, 878 on cp-02.
  - cp-03 rejected nothing.
- **KCM (cp-01):**
  - Rate-limiter wait means: PUT 60 ms, POST 37 ms.
  - 6,040 409 conflicts on PUT, the same as run 02.
  - Queue peaks: deployment 1,997 (16:54, patch), endpoint_slice 1,325 (16:45:35), GC `attempt_to_delete` 4,740 and endpoint 1,184 (16:56:36), namespace 1,979 (16:58:47).
  - The namespace queue drains in about 14 minutes whatever the topology.
- **etcd:**
  - No leader change and no new failed proposals.
  - The DB file grew from 129 to 668 MiB, with 196 MiB in use at the end.
  - RSS stayed at ≤ 1.15 GiB.
- **Memory:** API server RSS peaked at 8.4 / 8.6 / 6.8 GiB.
- **Cilium / kubelet** on the sampled nodes: nothing abnormal.

## Recommendations

1. **Take load off the KCM leader's API server.** cp-01 is now the bottleneck: it serves the KCM's writes and still gets its `leastconn` share of client writes. Options:
   - give the control-plane nodes more vCPU (12–16), which also helps the RKE2 health probes, or
   - lower cp-01's HAProxy weight, or
   - point kube-burner directly at the two non-leader servers for the benchmark.
2. **Bypass the RKE2 etcd load balancer.** Set `kube-apiserver-arg: etcd-servers=https://<etcd-01>:2379,https://<etcd-02>:2379,https://<etcd-03>:2379` so that a single failed health check can no longer cut every stream at once. This also spreads reads off etcd-03. Run 03 shows that the failover still happens, whether or not it causes errors. The change needs testing on RKE2, which manages the flag and the client certificates.
3. **Rebalance until the API servers are even**, for example by rolling the Cilium agents. cp-03 is still at 28k goroutines against 45k. Rerun at the same settings to confirm that 0 errors is reproducible. Then try QPS 200 to measure the margin.
4. **Downsize etcd to 4 vCPU / 8 GiB, defragment before every run, and spread the CP and etcd VMs across Harvester hosts.** These are unchanged from run 02.
5. **Namespace cleanup:** raise `concurrent-namespace-syncs` on KCM. It is the only lever for the 14-minute cleanup.
