# Run 14 — api-intensive, 2000 iterations, QPS 300 / burst 400, balanced start

Results: `results-api-intensive-20261029T103532Z-C3yDQA`. Benchmark settings are the same as runs 12 and 13 (`ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true`, all metrics `required`, KCM qps 100 / burst 200 / 20 deployment and replicaset workers, `NODE_SAMPLE_COUNT=5`, `goaway-chance=0.001`, Cilium `k8s.apiServerURLs` and APF priority level). The only change is the state of the cluster at the start.

Cluster state at start:
- **The load was balanced.** Goroutines per API server were **39k on cp-01, 42k on cp-02 and 36k on cp-03** (31k / 6k / 78k in run 13). API server RSS was 5.2 / 5.3 / 5.9 GiB, and node memory 44–49 %.
- **etcd was not defragmented:** all three members were at **900 MiB, with 143 MiB in use**. No leader change or failed proposal during the run.
- **cp-02 is both the etcd leader and the KCM leader** for the whole run.

## Verdict

**The best run so far for pods: every pod was Ready within 5 s of its creation, and all 2,000 were Ready 1m55s after the job started (4m03s in run 13). The balanced start removed the creation-time APF storm and let the controllers keep up. But 596 Service creates timed out again, and 132 deployment patches were lost on one dead kube-burner connection.**

- **Better than run 13:**
  - Pod Ready p99 **5 s** (37 s), max **5 s** (86 s), average **3.0 s** (10 s).
  - Job start → all pods Ready: **1m55s** (4m03s). About 1 minute of that is the Service timeouts (Finding 1); without them, the pods would have been Ready about 1 minute after the start.
  - APF rejections **1,953** (9,156), all during the remove jobs, **none during creation**. The `cilium` level again rejected nothing.
  - The KCM leader sent 175–244 requests/s during creation, at 0.1–0.3 s each (40–52/s at 0.5–1.8 s in run 13). Its deployment queue was empty by 10:38:20.
  - Node CPU was spread: 6.1 / 7.5 / 6.1 cores during creation, instead of one node at 100 %.
  - Patch 2m46s (3m10s); cleanup 11m34s (14m14s).
- **Worse than run 13:**
  - **596 Service create timeouts** (0), each returned as a 504 after 60 s and created by kube-burner's retry. All three API servers created Services at once, and each one's ClusterIP allocator was saturated (Finding 1).
  - **132 failed deployment patches** (2.2 % of the 6,000), lost when one HTTP/2 connection was closed by client-go's health check at 10:42:05 (Finding 2). This is the third run with such a drop (runs 11, 13, 14).
  - remove-deployments / services / configs: 19 / 19 / 34 s (14 / 25 / 35 s).

## Comparison

| | run 11 | run 12 | run 13 | **run 14** |
|---|---|---|---|---|
| Change | goaway-chance=0.001 | Cilium `k8s.apiServerURLs` | Cilium APF level; cp-01 and cp-02 restarted, no rebalance | **Rebalanced (even goroutines); no defrag** |
| etcd DB at start (total / in use) | 150 / 90 MiB | 701 (cp-02: 161) / 168 MiB | 960 / 175 MiB | 900 / 143 MiB |
| Goroutines cp-01 / cp-02 / cp-03 | 33k / 88k / 4k | 68k / 3.4k / 46k | 31k / 6k / 78k | **39k / 42k / 36k** |
| KCM leader | cp-02 | cp-03 | cp-03 | cp-02 (also etcd leader) |
| kube-burner errors | 85 (read, connection closed) | 0 | 66 (read, connection dropped) | **728: 596 Service timeouts (retried), 132 patches (connection dropped)** |
| Service create timeouts | 0 | 0 | 0 | **596** |
| Job start → all pods Ready | 4m06s | 3m17s | 4m03s | **1m55s** |
| Pod Ready p99 / max / avg | 167 / 212 / 82 s | 115 / 152 / 32 s | 37 / 86 / 10 s | **5 / 5 / 3.0 s** |
| Initialized p99 | 1 s | 5 s | 5 s | 1 s |
| PodScheduled p99 | 1.4 s | 1 s | 4 s | 1.7 s |
| Read / patch | 2m53s / 3m1s | 2m52s / 2m42s | 2m52s / 3m10s | 2m53s / 2m46s |
| remove-deployments / services / configs | 11 / 14 / 32 s | 11 / 17 / 19 s | 14 / 25 / 35 s | 19 / 19 / 34 s |
| APF rejections | 31,289 | 18,851 | 9,156 (0 for Cilium) | **1,953** (0 for Cilium, 0 during creation) |
| 5xx | 2 | 0 | 16 | 596 (all Service create 504s) |
| etcd failed proposals | 0 | 0 | 0 | 0 |
| Peak node CPU cp-01 / cp-02 / cp-03 | 91 / 92 / 20 % | 99 / 26 / 91 % | 58 / 28 / 100 % | 78 / 94 / 92 % |
| Namespace cleanup | 15m16s | 13m19s | 14m14s | **11m34s** |

## Findings

### 1. Service creates: all three ClusterIP allocators were saturated

With the load balanced, HAProxy `leastconn` spread kube-burner's connections over all three servers, so all three created Services at the same time (in runs 12 and 13, a nearly idle cp-02 did most of them).

10:36:33–10:37:34, the window where most Services were created:

| Server | ClusterIP allocations | Mean allocation | Allocator lock busy | etcd create latency (API server side) | Mean Service POST | 504 timeouts |
|---|---|---|---|---|---|---|
| cp-01 | 774 | 77 ms | **101 %** | 68 ms | 27 s | 193 |
| cp-02 | 477 | 108 ms | **85 %** | 58 ms | 12 s | 0 |
| cp-03 | 819 | 74 ms | **101 %** | 59 ms | 28 s | 403 |
| run 13 cp-02 (17:22:30) | 364 | 13 ms | 9 % | 9–11 ms | 2.0 s | 0 |

- "Allocator lock busy" is the allocation time summed over the window, divided by the window length. In Kubernetes 1.36 each API server allocates one ClusterIP at a time under a mutex ([run 12](./run_12_analysis.md), Finding 1), so 100 % means Services were queueing for the lock.
- At 74–108 ms per allocation, the three servers together could allocate about **36 Services/s** (13 + 9 + 13.5).
- kube-burner sent Services at about **73/s**: iterations 200 → 1,800 took 22 s (10:36:21 → 10:36:43). So the queue grew by about 37 per second, and the Services at the back waited more than the API server's 60 s request timeout.
- The 596 timed-out creates were all sent between 10:36:06 and 10:36:20 and failed 60 s later (10:37:06–10:37:20). Each one was retried once and succeeded, so the last iteration only completed at 10:37:43, about 1 minute later than without the timeouts. Pods were all Ready 6 s after that.
- In run 13, cp-02 allocated in 13 ms, so one server alone could do about 75 Services/s, as fast as kube-burner sent them.

Each allocation writes an `IPAddress` object to etcd, so the allocation time follows etcd write latency, and etcd was about 6× slower than in run 13:

| | run 13, creation | run 14, creation |
|---|---|---|
| etcd proposals committed | 200–440/s | **480–730/s** |
| WAL fsync / backend commit | 1.4–4.6 / 2.7–13.6 ms | 1.8–4.4 / 3.4–12.7 ms |
| Peer round-trip time | 5–46 ms (cp-03: 28–91 ms) | **38–86 ms on all members in the busiest minute** |
| API server → etcd create | 9–17 ms (cp-03: 57–551 ms) | **39–68 ms on all servers** |
| Control-plane node CPU | cp-03 at 75–100 %, the others under 60 % | **all 3 nodes at 6–7.5 cores (76–94 %)** |

- etcd's disk is not the limit: fsync and commit times are similar to run 13. etcd's own CPU stayed under 0.5 core.
- What changed is the work done at the same time. The controllers were no longer stalled, so the KCM created ReplicaSets and pods, the scheduler bound them and the kubelets updated their status while kube-burner was still creating objects. etcd committed about 65 % more proposals per second at the peak, and all three control-plane nodes were at 75–94 % CPU, where etcd shares the CPU with a busy API server.
- The peer round-trip time, which is part of every write, rose to 38–86 ms on all members. That fits etcd being scheduled late on busy nodes rather than a slow disk.
- So the faster the controllers, the slower each ClusterIP allocation, at this Service creation rate. The upstream fix (kubernetes/kubernetes#142758, v1.38) removes the per-server lock.

### 2. kube-burner lost one HTTP/2 connection at the start of the patch job

- At 10:42:05–10:42:08, 16 s into the patch job, 132 `PATCH deployments` through the VIP failed with `http2: client connection force closed via ClientConn.Close`. client-go also logged 33 `Unexpected error when reading response body` with the same error.
- There was no `unexpected EOF` this time, only the forced close. client-go closes a connection when it has received no frame for 30 s and a ping then gets no answer within 15 s. So the connection went silent around 10:41:20, during the read job's last iteration, and nothing failed until the patch job reused it.
- No API server restarted, no server returned 5xx outside the Service creates, and all three handled PATCH and GET normally between 10:41:12 and 10:42:44. cp-03 received fewer patches (2.0k against 5.4k and 4.5k), which would fit the dead connection going there, but the metrics can't show it.
- This now happens in 3 of the last 4 runs, each time a few seconds into a job: run 11 (read, 85 GETs), run 13 (read, 66), run 14 (patch, 132). It costs a few percent of one job's operations, and the created objects are not affected.

### 3. APF: no rejections during creation

| Server | Priority level (flow schema) | Reason | Rejections |
|---|---|---|---|
| cp-03 | workload-high (kube-system-service-accounts) | queue-full | 1,127 |
| cp-02 | workload-high (kube-system-service-accounts) | queue-full | 434 |
| cp-01 | workload-high (kube-system-service-accounts) | queue-full | 392 |
| all | cilium | — | **0** |

- All rejections came between 10:44:28 and 10:46:44, during remove-services, remove-configs and the start of namespace deletion. They were WATCH re-establishments: services 1,044, secrets 774, configmaps 75, endpointslices 60, and a few on each Traefik CRD.
- During creation there were none, against 7.1k on cp-03 in run 13. The watch storms in runs 12 and 13 came from one overloaded server; with three servers sharing the load, no server fell behind enough.
- The `cilium` level queued up to 247 requests on cp-01 and 210 on cp-02 during remove-services, and executed up to 42 (its concurrency limit), without rejecting any. On cp-03 it never had more than 1 request executing, so few Cilium agents seem to have been connected to cp-03 at that time.

### 4. Other

- KCM (cp-02): deployment queue 1,629 at 10:36:39, 1,488 at 10:37:37 and 0 at 10:38:20. Rate-limiter wait under 33 ms.
- Memory peaks: API server RSS 6.2 / 6.7 / 6.5 GiB; node 8.3 / 10.8 / 9.1 GiB. cp-02, with both leaders, uses the most.
- etcd: in-use space peaked at 632 MiB, so the undefragmented 900 MiB file did not grow. Slow applies rose by 1.7k on cp-01, 331 on cp-02 and 567 on cp-03.
- Sampled workers: 7 new sandboxes in 0.7–1.2 s, CNI `PUT /v1/endpoint` 0.15–0.31 s. Cilium got no 429s. The `host` label shows 2 agents with the VIP and 3 with `127.0.0.1` as bootstrap URL (see [run 13](./run_13_analysis.md), Finding 4).
- Status codes: 12.8k 403 POSTs during namespace deletion (creates in terminating namespaces) and 6.1k 409 PUTs on cp-02 (KCM update conflicts) are expected.

## Recommendations

1. **Keep the pre-run procedure.** Rebalancing gave the best pod results so far. Defragmenting etcd did not matter in this run (fsync and commit were fast), but it keeps the database small.
2. **Decide how to treat the Service create limit.** At about 60 ms per etcd write, the cluster allocates about 36 Services/s, and this workload sends about 73/s. Options:
   - Measure the limit: run once at `QPS=150 BURST=200`, which halves the Service rate. If the timeouts disappear, the allocator is confirmed as the only limit at this scale.
   - Lower etcd write latency: the control-plane nodes peaked at 92–94 % of 8 vCPU, with etcd on the same nodes as the API server. More vCPU (for example 12–16) should bring the peer round-trip time and allocation time down.
   - Upgrade to v1.38 when available, for the concurrent allocator.
   - Don't raise the API server's `--request-timeout`: it would hide the queue, not shorten it.
3. **Find what kills kube-burner's connection** (runs 11, 13 and 14). Right after the next run with such errors, collect from `bench-lb-01` and `bench-lb-02` (run 13, recommendation 4):
   - `sudo journalctl -u haproxy --since ... --until ...` around the last silent moment (here about 10:41:20, 45 s before the errors). The `option tcplog` termination flags show which side closed.
   - `sudo journalctl -u keepalived` for VRRP state changes.
   - If the logs show nothing, run once with kube-burner's kubeconfig pointed at one API server directly instead of the VIP. If the errors stop, the VIP path is the cause.
4. **Still open from run 13:** the kube-system `ByUser` FlowSchema (recommendation 2) now only matters during removal, so it is lower priority. Recording `apiserver_terminated_watchers_total` (recommendation 3) is still useful to explain the remaining 429s.
5. **Check which servers the Cilium agents use.** The `cilium` level was almost unused on cp-03. On a few workers, `sudo ss -tnp | grep cilium-agent` shows which API server each agent is connected to. If cp-03 is avoided, run `rebalance.sh` with Cilium again.
