# Split control plane, run 10 — api-intensive, 2000 iterations, QPS 300 / burst 400

Results: `results-api-intensive-20261106T143416Z-zqYUuJ`. This is a repeat of [run 09](./run_09_analysis.md). The topology, cluster configuration and parameters are unchanged:
- 3 control-plane nodes (16 vCPU / 16 GiB) and 3 dedicated etcd nodes (8 vCPU / 16 GiB), with 1,000 workers;
- direct etcd connections;
- separate APF FlowSchemas and priority levels for Cilium and traefik;
- `QPS=300 BURST=400 ITERATIONS=2000 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`;
- the bench VM (`bench-net-01`) is still 1 vCPU.

Preparation:
- The etcd DB was back to a 110 MiB file (654 MiB at the end of run 09), so it was defragmented before the run.
- **14:34:16:** run start; kube-burner triggered the job at 14:34:36.

Cluster state at start:
- **Stored objects:** 8.7k, as in run 09.
- **etcd DB:** 110 MiB file, 86 MiB in use. It grew to 664 MiB during the run.
- **Goroutines:** 41.4k / 38.5k / 40.7k (cp-01 / cp-02 / cp-03), within 7 %.
- **API server RSS:** 6.6 / 6.8 / 7.6 GiB.
- **Leaders:** etcd-01 led throughout, with no leader changes. The KCM leader was cp-01.

## Verdict

**Same speed as run 09, but 37 Service creates timed out, all on cp-03.**
- kube-burner logged **37 errors**, all `Service/service-1` creates in namespaces 1892–1989 (the last ~100 iterations), at 14:35:56–58. Each was retried once and succeeded; all 2,000 Services were verified.
- These were the API server's **34 s create timeout**: the API server returned 504 on 37 POSTs, all on cp-03, and the 37 matching etcd `create` errors are the cancelled writes. The requests were sent at 14:35:21–23, 34 s before the errors.
- **There was no etcd problem.** etcd had no leader change, no failed proposal and no slow apply during creation. Its WAL fsync stayed ≤ 2.9 ms, and ClusterIP allocation took 65–68 ms, the same as run 09.
- **The cause is load placement:** cp-03 received **894 of the 2,037 Service creates (44 %)**, against 749 (37 %) for the busiest server in run 09. One server allocates at most about 15 ClusterIPs/s, so cp-03's queue grew past 34 s for the last ~100 iterations.

The run was otherwise as good as run 09:
- 0 other errors: no other 5xx, no 429, no APF rejection, no request termination;
- Pod Ready p99 5 s, max 6 s, avg 3.10 s;
- creation job 1m51s, read 2m52s, patch 2m34s, the same as run 09;
- peak CP node CPU 64 / 59 / 55 %, etcd nodes ≤ 21 %.

**Correction to run 09:** the create timeout is 34 s, not 60 s (it was measured in haproxy runs 04–06). Run 09's longest wait of about 30 s was therefore within about 4 s of the timeout, not half of it. QPS 300 is the edge for this workload, not a working rate with margin: one run of two crossed it.

## Comparison

| | haproxy run 14 | split run 09 | **split run 10** |
|---|---|---|---|
| Control plane | 3 × 8 vCPU, etcd stacked | 3 × 16 vCPU + 3 etcd | 3 × 16 vCPU + 3 etcd |
| QPS / burst | 300 / 400 | 300 / 400 | 300 / 400 |
| Goroutines at start | 39k / 42k / 36k | 39.8k / 39.4k / 41.3k | 41.4k / 38.5k / 40.7k |
| Stored objects / etcd DB at start | – / 900 MiB | 8.7k / 110 MiB | 8.7k / 110 MiB |
| kube-burner errors | 728 (596 Service timeouts, 132 patches) | 0 | **37 (Service timeouts, retried)** |
| API server 5xx / 429 / APF rejections | 596 / – / 1,953 | 0 / 0 / 0 | **37 (504, cp-03) / 0 / 0** |
| Broken etcd connections | (stacked) | 0 | 0 |
| Iterations 200 → 1,800 | 22 s | 22 s | 21 s |
| Iteration 1,800 → all creates done | about 60 s (timeouts, retries) | 30 s | **40 s (timeouts, retries)** |
| Trigger → all creates done | 109 s | 76 s | **85 s** |
| Job duration (all pods Ready) | 1m55s | 1m51s | 1m51s |
| Service creates per server | 774 / 477 / 819 (peak window) | 536 / 749 / 715 | **604 / 539 / 894** |
| Largest share | 40 % | 37 % | **44 %** |
| Mean Service POST, creation | 27 / 12 / 28 s | 10.6 / 16.5 / 13.9 s | 14.2 / 10.0 / **18.6 s** |
| Mean Service POST, second half | – | – | 17.9 / 13.0 / **24.8 s** |
| Mean ClusterIP allocation | 77 / 108 / 74 ms | 70 / 70 / 73 ms | 66 / 68 / 65 ms |
| Service creation rate, second half | about 34/s | about 37/s | about 31/s |
| API server process CPU, second half | – | 7.8 / 7.7 / 7.7 cores | 8.1 / 7.2 / 7.2 cores |
| API server → etcd create latency, creation | 68 / 58 / 59 ms | 51 / 62 / 57 ms | 54 / 64 / 63 ms |
| Peak CP node CPU, creation | 78 / 94 / 92 % | 71 / 66 / 65 % | 64 / 59 / 55 % |
| Peak CP node CPU, patch | – | 64 / 56 / 57 % | 56 / 44 / 50 % |
| Peak etcd node CPU | (stacked) | ≤ 24 % | ≤ 21 % |
| Pod Ready p99 / max / avg | 5 / 5 / 3.0 s | 5 / 7 / 3.05 s | 5 / 6 / 3.10 s |
| PodScheduled p99 / Initialized p99 | 1.7 s / 1 s | 2.0 s / 2 s | 1.9 s / 1 s |
| Read / patch | 2m53s / 2m46s | 2m52s / 2m35s | 2m52s / 2m34s |
| remove-deployments / services / configs | 19 / 19 / 34 s | 11 / 17 / 19 s | 11 / 14 / 22 s |
| API server peak RSS | – | 7.8 / 7.3 / 8.0 GiB | 7.2 / 7.0 / 7.8 GiB |
| Namespace cleanup | 11m34s | 13m20s | 13m27s |

Triples are cp-01 / cp-02 / cp-03. Scrapes came about every 45 s. The windows are:
- **Creation:** 14:34:36 → 14:36:15.
- **Second half:** 14:35:18–14:35:20 → 14:36:14–14:36:15. Rates are computed over the ~42 s until the last create returned at 14:36:01.

## Findings

### 1. One server took 44 % of the Services and its queue crossed the 34 s timeout

| | cp-01 (KCM leader) | cp-02 | cp-03 |
|---|---|---|---|
| Service creates (ClusterIP allocations) | 604 | 539 | **894** |
| Of which in the second half | 380 | 320 | **595** |
| Rate, second half | 9.0/s | 7.6/s | **14.2/s** |
| Mean allocation | 66 ms | 68 ms | 65 ms |
| Allocator busy, second half | about 60 % | about 52 % | **about 92 %** |
| Mean Service POST, second half | 17.9 s | 13.0 s | **24.8 s** |
| Service POST 504 (timeouts) | 0 | 0 | **37** |

- kube-burner sent about 73 Services/s from iteration 200 to 2,000 (14:35:00 → 14:35:23).
  - cp-03 received about 44 % of them, about 32/s, and could allocate at most about 15/s (one every 65 ms).
  - Its queue grew for the whole send phase, so the last ~100 Services waited more than 34 s.
- cp-01 and cp-02 had spare allocator time: the three servers together created only about **31 Services/s** in the second half, against 37/s in run 09, when the load was more even.
- **The per-server share is luck.** HAProxy `leastconn` balances TCP connections, not requests. kube-burner sends its requests over a few long-lived HTTP/2 connections, so the share of each server depends on where those connections landed. Over the QPS 300 runs, the busiest server took 37–44 % of the Services.
- kube-burner uses an admin kubeconfig, so its requests are **exempt from APF**. At 14:35:20, cp-03 had 480 exempt requests executing (306 / 217 on the others), which was mostly its Service queue. APF can't shed or spread this load.
- **The timeouts were harmless for the run.**
  - Each timed-out Service had allocated a ClusterIP. The allocation was rolled back, which is why there were 2,037 allocations for 2,000 Services.
  - The retries finished by 14:36:01, 9 s later than run 09. The job still took 1m51s, and pod latency was unchanged.

The limit is the same as in run 09: in Kubernetes 1.36 each API server allocates one ClusterIP at a time, about 15/s at 65–70 ms. It is fixed in 1.38 (kubernetes/kubernetes#142758).

### 2. The 34 s create timeout

- The API server applies a 34 s timeout to create requests that don't set `?timeout=`. kube-burner's creates evidently don't set one.
- The errors confirm it: they came at 14:35:56–58, 34–35 s after the last iterations were sent (14:35:21–23).
- Haproxy runs 04–06 measured this already. Run 09 and earlier split-CP analyses used 60 s, the general `--request-timeout`, which applies to other requests.
- With 34 s, run 09's longest wait of about 30 s left only about 4 s of margin. Run 10 shows how easily the margin goes: a 7-point shift in one server's share was enough.

### 3. etcd was healthy; no TCP stall again

- No leader change, no new failed proposals, pending proposals ≤ 10.
- WAL fsync ≤ 2.9 ms, backend commit ≤ 7.6 ms, peer RTT ≤ 5.4 ms, CPU ≤ 0.79 cores per member.
- Slow applies: 0 / 0 / 1 during creation. The others (+21 / +18 / +67 in total) came at the start of patch (14:40) and during cleanup.
- API server → etcd create latency was 54–64 ms during creation, the same as run 09.
- The only `etcd_request_errors_total` are the 37 cancelled `create` calls on cp-03, which appeared at 14:36:15 together with the 504s.

This is the second QPS 300 run in a row without a 10 s etcd stall (runs 07 and 08 each had 2).

### 4. The traefik priority level queued during remove-services

At the 14:43:10–14:43:13 sample, during remove-services (14:43:09 → 14:43:18):
- the `traefik` priority level had 36 / 41 / 45 requests executing and **264 / 466 / 362 in queue**;
- on cp-02, `system-nodes` (kubelets) had 83 executing and 97 in queue, and `cilium` had 69 executing.

Nothing was rejected (the traefik level has 64 queues of 500), no request was terminated, and remove-services took 14 s, faster than run 09's 17 s. The queues were empty at the next sample.

Deleting 2,000 Services at once makes all ~1,000 traefik pods react together, most likely re-establishing their Service and EndpointSlice watches. The metrics have no verb or user label, so this can't be confirmed. Run 09 probably had the same burst: its samples fell just before and after remove-services. This is the isolation the dedicated traefik FlowSchema was meant to provide: the burst stayed in its own priority level.

### 5. Everything else

- **KCM (cp-01):** 6,066 PUT 409s and no 5xx. Client rate-limiter waits were the same as run 09 window for window. Queue peaks: GC `attempt_to_delete` 5,077, deployment 1,995, namespace 1,982, **endpoint 1,925** (387 in run 09), replicaset 1,258, endpoint_slice 763. The endpoint queue drained within the run.
- **APF during creation:** on cp-01 only, 11 requests queued in `workload-high` at 14:35:18. Nothing else queued.
- **Read and patch:** 2m52s and 2m34s, the same as run 09. Both are bound by the client rate.
- **Cleanup:** removes took 11 / 14 / 22 s, and namespace cleanup 13m27s. During cleanup cp-01 ran at 11–14 % node CPU and the others at about 6–7 %, as in run 09.
- **Memory:** API server RSS peaked at 7.2 / 7.0 / 7.8 GiB.

## Recommendations

1. **Treat QPS 300 as the edge for this workload, not the working rate.**
   - It ran clean once and had 37 timeouts once, depending on how kube-burner's connections landed. The timeouts are retried and cost about 10 s, but they make runs hard to compare.
   - For error-free comparison runs, use QPS 200–250. For QPS 300, accept a few dozen retried Service timeouts as normal.
2. **Count retried Service timeouts separately from real failures** when comparing runs. A 504 on `POST services` that succeeded on retry, with 65–70 ms allocations and no etcd errors besides the cancelled writes, is a queue on one API server, not a cluster fault.
3. **To push the control plane further, change the workload, not the cluster** (unchanged from run 09):
   - drop the Service from the template, or use `clusterIP: None` (headless, no allocation);
   - or run a 1.38 build.
   Raising `--request-timeout` would not help: the 34 s create timeout is separate, and a longer timeout would hide the queue, not shorten it.
4. **Keep repeating to watch for etcd stalls.** Two QPS 300 runs without one is encouraging, but runs 07–08 had 2 each. Collect nstat and ping data if they come back.
5. **Unchanged:**
   - Enlarge the bench VM (1 vCPU / 2 GiB).
   - Downsize etcd to 4 vCPU / 8 GiB: ≤ 21 % CPU and ≤ 2 GiB memory.
   - Configure off-cluster etcd snapshots.
