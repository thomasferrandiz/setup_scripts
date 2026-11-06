# Split control plane, run 09 — api-intensive, 2000 iterations, QPS 300 / burst 400

Results: `results-api-intensive-20261106T120001Z-TjpWBW`. The topology and cluster configuration are the same as [run 08](./run_08_analysis.md):
- 3 control-plane nodes (16 vCPU / 16 GiB) and 3 dedicated etcd nodes (8 vCPU / 16 GiB), with 1,000 workers;
- direct etcd connections;
- separate APF FlowSchemas and priority levels for Cilium and traefik.

**New: the client rate is doubled to `QPS=300 BURST=400`** (150 / 200 in runs 01–08), as in haproxy runs 3–14. The other settings are unchanged: `ITERATIONS=2000 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`. The bench VM (`bench-net-01`) is still 1 vCPU.

Preparation:
- No rebalance since run 08's preparation (Cilium at 10:02, traefik at 10:04), so the rebalance Events had expired.
- **11:57:51–11:57:54:** defrag.
- **12:00:01:** run start; kube-burner triggered the job at 12:00:21.

Cluster state at start:
- **Stored objects:** 8.7k (45.9k in run 08).
- **etcd DB:** 110 MiB file, 91 MiB in use. It grew to 654 MiB during the run.
- **Goroutines:** 39.8k / 39.4k / 41.3k (cp-01 / cp-02 / cp-03), within 5 %, two hours after the rebalance.
- **API server RSS:** 7.8 / 6.5 / 6.3 GiB.
- **Leaders:** etcd-01 led throughout, with no leader changes. The KCM leader was cp-01.

## Verdict

**The first clean run at QPS 300.**
- **0 kube-burner errors, 0 API server 5xx, 0 429s, 0 APF rejections and 0 etcd request errors.** No API server logged an etcd connection error, so this run had no TCP stall.
- **Pods were as fast as at QPS 150:** Ready p99 5 s, max 7 s, avg 3.05 s.
- **Every phase was the fastest of the split series:**
  - creation job 1m51s;
  - read 2m52s, half of run 08's 5m39s, because the read job is bound by QPS;
  - patch 2m35s;
  - removes 11 / 17 / 19 s.
- **The control plane had headroom:**
  - peak node CPU 71 / 66 / 65 % during creation;
  - etcd nodes ≤ 24 %.

The same rate on the stacked 8 vCPU control plane (haproxy run 14) caused 596 Service create timeouts, and all three nodes reached 78–94 % CPU.

**Service creation is the limit again, but within the timeout.**
- kube-burner sent about 73 iterations/s, so about 73 Services/s.
- The three API servers created about **37 Services/s** at peak, so Services queued:
  - mean Service POST was 10.6 / 16.5 / 13.9 s;
  - the last creates returned about 30 s after the last iteration was sent.
- That is within about 4 s of the API server's 34 s create timeout. (This analysis first compared it with 60 s, the general request timeout. [Run 10](./run_10_analysis.md) repeated this run and crossed the 34 s limit.)

## Comparison

| | haproxy run 14 | split run 08 | **split run 09** |
|---|---|---|---|
| Control plane | 3 × 8 vCPU, etcd stacked | 3 × 16 vCPU + 3 etcd | 3 × 16 vCPU + 3 etcd |
| QPS / burst | 300 / 400 | 150 / 200 | **300 / 400** |
| Goroutines at start | 39k / 42k / 36k | 39.6k / 39.8k / 40.7k | 39.8k / 39.4k / 41.3k |
| Stored objects / etcd DB at start | – / 900 MiB | 45.9k / 126 MiB | 8.7k / 110 MiB |
| kube-burner errors | 728 (596 Service timeouts, 132 patches) | 0 | **0** |
| API server 5xx / 429 / APF rejections | 596 / – / 1,953 | 2 / 0 / 0 | **0 / 0 / 0** |
| Broken etcd connections | (stacked) | 2 | **0** |
| Iterations 200 → 1,800 | 22 s | 43 s | 22 s |
| Iteration 1,800 → all creates done | about 60 s (timeouts, retries) | 23 s | 30 s |
| Trigger → all creates done | 109 s | 93 s | **76 s** |
| Job duration (all pods Ready) | 1m55s | 1m55s | **1m51s** |
| Service creates per server | 774 / 477 / 819 (peak window) | 652 / 559 / 789 | 536 / 749 / 715 |
| Mean Service POST, creation | 27 / 12 / 28 s | 5.4 / 9.7 / 5.7 s | 10.6 / 16.5 / 13.9 s |
| Mean ClusterIP allocation | 77 / 108 / 74 ms | 65 / 86 / 76 ms | 70 / 70 / 73 ms |
| Allocator busy, while creating | 101 / 85 / 101 % | 41 / 65 / 56 % | 63 / 99 / 96 % |
| Service creation rate, peak | about 34/s | about 23/s (client-bound) | **about 37/s** |
| API server process CPU, peak window | – | 7.6 / 6.3 / 6.8 cores | 7.8 / 7.7 / 7.7 cores |
| API server → etcd create latency, creation | 68 / 58 / 59 ms | 42 / 65 / 56 ms | 51 / 62 / 57 ms |
| Peak CP node CPU, creation | 78 / 94 / 92 % | 54 / 57 / 52 % | 71 / 66 / 65 % |
| Peak CP node CPU, patch | – | 64 / 64 / 58 % | 64 / 56 / 57 % |
| Peak etcd node CPU | (stacked) | ≤ 19 % | ≤ 24 % |
| Pod Ready p99 / max / avg | 5 / 5 / 3.0 s | 5 / 7 / 3.0 s | **5 / 7 / 3.05 s** |
| PodScheduled p99 / Initialized p99 | 1.7 s / 1 s | 1.8 s / 2 s | 2.0 s / 2 s |
| Read / patch | 2m53s / 2m46s | 5m39s / 3m06s | **2m52s / 2m35s** |
| remove-deployments / services / configs | 19 / 19 / 34 s | 21 / 26 / 34 s | **11 / 17 / 19 s** |
| API server peak RSS | – | 7.5 / 7.2 / 7.0 GiB | 7.8 / 7.3 / 8.0 GiB |
| Namespace cleanup | 11m34s | 13m19s | 13m20s |

Triples are cp-01 / cp-02 / cp-03. The windows are aligned on the last server's sample:
- **Creation:** 12:00:21 → 12:01:57.
- **Peak:** 12:01:03–12:01:06 → 12:01:57.
- **While creating:** from the peak start to 12:01:37, when the last create returned.

## Findings

### 1. Service creation: about 37 Services/s, just under the timeout

In the run's second half (12:01:05 → 12:01:37), the three servers allocated 1,186 ClusterIPs:

| | cp-01 (KCM leader) | cp-02 | cp-03 |
|---|---|---|---|
| Allocations | 298 | 466 | 422 |
| Rate | 9.0/s | 14.6/s | 13.6/s |
| Mean allocation | 70 ms | 70 ms | 73 ms |
| Allocator busy | 63 % | **99 %** | **96 %** |
| Mean Service POST (whole creation) | 10.6 s | 16.5 s | 13.9 s |

- In Kubernetes 1.36, each API server allocates one ClusterIP at a time (haproxy run 12). At about 70 ms per allocation, a server can do at most about 14 Services/s, so the three together can do about **40/s**. Here they reached about 37/s, against about 34/s in haproxy run 14 at 74–108 ms.
- **The gain from 16 vCPU is in allocation time:** 70–73 ms here, against 74–108 ms in haproxy run 14. Allocation time follows the API server's etcd write latency, which was 51–62 ms.
- kube-burner sent Services at about 73/s, so they queued:
  - iteration 2,000 was sent around 12:01:10, and the last create returned at 12:01:37;
  - **the longest wait was about 30 s**, just under the 34 s create timeout that 596 Services crossed in haproxy run 14.
- cp-01 was not saturated (63 %). It received the fewest Service creates (536). HAProxy `leastconn` sends fewer new requests to the server already handling the most, and cp-01 is also the KCM leader.

This limit is fixed in Kubernetes 1.38 (kubernetes/kubernetes#142758). Until then, three API servers at this size top out at about 40 Services/s. A higher QPS, or a less even spread of Services across the servers, pushes the wait past 34 s: run 10 had 37 timeouts at the same QPS.

### 2. No etcd TCP stall this time

- The API server logs (11:59–12:24) contain no etcd client errors at all: no `connection timed out`, no `error reading from server`, and no failed `createTransport` except the usual canceled dial.
- Runs 07 and 08 each had 2 stalls.
- The run was shorter, with less time under load (creation 76 s, read 2m52s), so this may just be chance. The open question from run 08 remains.
- etcd stayed idle:
  - CPU ≤ 0.82 cores (≤ 24 % of the node);
  - WAL fsync 1.6–2.2 ms, backend commit 3.8–5.2 ms;
  - peer RTT 2.8–3.1 ms;
  - pending proposals ≤ 9, 0 failed proposals.
- Slow applies were 11 / 13 / 160.
  - etcd-03's 160 came almost all at 12:09:00–12:11:00, during remove-configs and the start of namespace cleanup.
  - All three members logged a handful of 100–220 ms read-only ranges at 12:09:56, 12:10:42, 12:13:25 and 12:14:06, during the deletes.
  - None of this happened during creation.

### 3. APF: a brief queue on the KCM leader, no rejections

At the 12:01:03 sample, at the height of creation, cp-01 had requests in queue:
- 22 in `kube-system-service-accounts` (`workload-high`): the controllers;
- 7 in `cilium`;
- 6 for `kube-scheduler`.

`system-nodes` was executing 21 requests. Nothing was rejected, and the queues were empty at the next sample. cp-02 and cp-03 queued nothing.

The traefik priority level stayed idle. No API server force-closed a watcher (no request terminations).

### 4. Everything else

- **KCM (cp-01):**
  - 6,080 PUT 409s and no 5xx;
  - client rate-limiter wait 21 ms per PUT and 5.6 ms per POST (`kube-api-qps` 100 / burst 200);
  - queue peaks: deployment 1,988, namespace 1,979, GC `attempt_to_delete` 4,251, replicaset 1,101, endpoint_slice 779.
- **ClusterIP repair noise:** each API server logged `repairip.go ... is not allocated; repairing` during creation, as in run 07. This is harmless.
- **Read job:** 2m52s, the same as every QPS 300 haproxy run. It is bound by the client rate.
- **Patch:** 2m35s, the fastest of all series. Pod Ready during patch was p99 5 s, max 7 s.
- **Cleanup:**
  - removes took 11 / 17 / 19 s, and namespace cleanup 13m20s, the same as run 08;
  - during cleanup, cp-01 (the namespace and GC controllers) ran at 11–15 % node CPU and the others at about 7 %. Cleanup is bound by the namespace controller, not by the cluster.
- **Memory:**
  - API server RSS peaked at 7.8 / 7.3 / 8.0 GiB, and node memory was 52–67 %;
  - cp-01 node memory was 10.8 GiB of 16 at start, the highest of the three.

## Recommendations

1. **Treat QPS 300 as this cluster's limit for this workload.** It is error-free here, with Pod Ready p99 5 s and peak CP CPU ≤ 71 %. However, [run 10](./run_10_analysis.md) had 37 Service timeouts at the same rate, so for error-free runs use QPS 200–250.
2. **Don't go above QPS 300 with this workload on 1.36.**
   - The limit is ClusterIP allocation, about 40 Services/s across three API servers, and the longest wait was already about 30 s of the 34 s create timeout. (Run 10 showed that QPS 300 itself is at the edge.)
   - To test the control plane at higher rates, change the workload, not the cluster:
     - drop the Service from the template, or use `clusterIP: None` (headless, no allocation);
     - or run a 1.38 build.
3. **Repeat QPS 300 once or twice** to see whether the etcd TCP stalls (runs 07–08) come back under this load. Collect the nstat and ping data suggested in run 08.
4. **Enlarge the bench VM before going further.** It is still 1 vCPU / 2 GiB and opened every connection of this run. A faster client may shorten the 24 s before iteration 200, and it would make the job-start TLS storms less risky.
5. **Unchanged:**
   - Downsize etcd to 4 vCPU / 8 GiB: ≤ 24 % CPU and ≤ 2 GiB memory.
   - Configure off-cluster etcd snapshots.
