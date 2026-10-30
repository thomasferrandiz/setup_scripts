# Run 15 — api-intensive, 2000 iterations, QPS 150 / burst 200, balanced start

Results: `results-api-intensive-20261029T142432Z-niTmxc`. Settings are the same as run 14, except kube-burner's rate: **`QPS=150 BURST=200`** (300 / 400 before). This is the test proposed in [run 14](./run_14_analysis.md) (recommendation 2): halve the Service creation rate to check whether the ClusterIP allocator is the only reason for the Service timeouts.

Cluster state at start (same as run 14, no restart in between):
- **Balanced:** goroutines 40k / 43k / 35k on cp-01 / cp-02 / cp-03. API server RSS 5.7 / 5.9 / 5.8 GiB.
- **etcd not defragmented:** 900 MiB file, 97 MiB in use. No leader change or failed proposal during the run.
- **cp-02 is both the etcd leader and the KCM leader** for the whole run.

## Verdict

**The first run with zero errors: no Service timeout, no dropped connection, no 5xx except one GET 500. Pods were as fast as in run 14 (Ready p99 5 s), and all 2,000 were Ready 2m00s after the start, the same as run 14's 1m55s. The allocator limit is confirmed: Service creates still queued for 10–23 s on average, but stayed under the 60 s timeout.**

- **Same as run 14:**
  - Pod Ready p99 **5 s**, max 6 s, average 3.0 s.
  - Job start → all pods Ready: **2m00s** (1m55s). Half the request rate, but no minute lost to retries.
  - APF: 1,743 rejections, all during the remove jobs (14:37–14:38). None during creation, none for Cilium.
- **Better than run 14:**
  - Errors: **0** (728). No Service timeout (596), and no dropped kube-burner connection (132 failed patches in run 14).
- **Slower, as expected at half the rate:**
  - Read job **5m39s** (2m53s): it is bound by kube-burner's QPS, so it took exactly twice as long. Read times can only be compared between runs with the same QPS.
  - Patch 2m58s (2m46s): this job mostly waits for rollouts, so the rate barely matters.

## Comparison

| | run 12 | run 13 | run 14 | **run 15** |
|---|---|---|---|---|
| Change | Cilium `k8s.apiServerURLs` | Cilium APF level; unbalanced | Rebalanced | **QPS 150 / burst 200** |
| Goroutines cp-01 / cp-02 / cp-03 | 68k / 3.4k / 46k | 31k / 6k / 78k | 39k / 42k / 36k | 40k / 43k / 35k |
| etcd DB at start (total / in use) | 701 / 168 MiB | 960 / 175 MiB | 900 / 143 MiB | 900 / 97 MiB |
| KCM leader | cp-03 | cp-03 | cp-02 | cp-02 |
| kube-burner errors | 0 | 66 | 728 | **0** |
| Service create timeouts | 0 | 0 | 596 | **0** |
| Job start → all pods Ready | 3m17s | 4m03s | 1m55s | 2m00s |
| Pod Ready p99 / max / avg | 115 / 152 / 32 s | 37 / 86 / 10 s | 5 / 5 / 3.0 s | **5 / 6 / 3.0 s** |
| Initialized p99 | 5 s | 5 s | 1 s | 1 s |
| PodScheduled p99 | 1 s | 4 s | 1.7 s | 1.6 s |
| Read / patch | 2m52s / 2m42s | 2m52s / 3m10s | 2m53s / 2m46s | 5m39s / 2m58s |
| remove-deployments / services / configs | 11 / 17 / 19 s | 14 / 25 / 35 s | 19 / 19 / 34 s | 18 / 22 / 40 s |
| APF rejections | 18,851 | 9,156 | 1,953 | 1,743 |
| 5xx | 0 | 16 | 596 | 1 |
| Peak node CPU cp-01 / cp-02 / cp-03 (creation) | 99 / 26 / 91 % | 58 / 28 / 100 % | 76 / 94 / 76 % | 86 / 95 / 82 % |
| Namespace cleanup | 13m19s | 14m14s | 11m34s | 11m54s |

## Findings

### 1. The allocator was still saturated, but the queue stayed under the timeout

kube-burner sent iterations 200 → 1,800 in 43 s (14:25:22 → 14:26:05), so about **37 Services/s**, half of run 14's 73/s.

Busiest window (about 14:25:35 → 14:26:28):

| Server | Service POSTs (whole run) | ClusterIP allocation | Allocator lock busy | API server → etcd create | Mean Service POST | Node CPU |
|---|---|---|---|---|---|---|
| cp-01 | 707 | 87 ms | 91 % | 68 ms | 12 s | 5.5 cores |
| cp-02 (etcd + KCM leader) | 570 | **157 ms** | **100 %** | 74 ms | **22 s** | 6.0 cores |
| cp-03 | 723 | 86 ms | 92 % | 67 ms | 10 s | 5.5 cores |
| run 14, same window | 2,070 in 60 s | 74–108 ms | 85–101 % | 58–68 ms | 12–28 s | 5.4–5.7 cores |

- At these allocation times, the three servers together can allocate about **30 Services/s** (11.5 + 6.4 + 11.6). kube-burner sent 37/s, so a queue still built up, at about 7/s instead of about 37/s in run 14.
- All creates had returned by 14:26:41, about 35 s after the last iteration started. So the longest wait was about 35–45 s, under the 60 s request timeout, but with little margin.
- cp-02's later Services waited longest: its last 166 POSTs (window ending 14:27:14) averaged 32 s.

**Halving kube-burner's rate did not make allocation faster.** The API server's etcd create latency was 67–74 ms, the same as in run 14 (58–68 ms). etcd committed 635–652 proposals/s (690–730 in run 14), with fsync 3–5 ms and backend commit 9–14 ms. So the write latency is set by the rest of the cluster's work during creation (controllers, scheduler, kubelets), and by the control-plane nodes' CPU (82–95 %), not by kube-burner's own rate. This refines run 14, Finding 1.

**cp-02 allocated at half the speed of the others** (157 ms against 86–87 ms), as in run 14 (108 ms against 74–77 ms). It hosts both the etcd leader and the KCM leader, and its node was the busiest at 95 %. The metrics can't show which of the two costs more, but it makes cp-02 the bottleneck for its share of Services. HAProxy `leastconn` balances connections, not requests, so it doesn't send fewer creates to a slower server.

### 2. No dropped connection this time

- No `force closed` or `unexpected EOF` errors. Runs 11, 13 and 14 each lost one kube-burner HTTP/2 connection near the start of a job.
- One run without it doesn't show that the lower rate fixed it: with QPS 150 kube-burner keeps fewer requests in flight per connection, but the drop may also be intermittent.

### 3. APF and Cilium

| Server | Priority level (flow schema) | Reason | Rejections |
|---|---|---|---|
| cp-02 | workload-high (kube-system-service-accounts) | queue-full | 847 |
| cp-03 | workload-high (kube-system-service-accounts) | queue-full | 429 |
| cp-01 | workload-high (kube-system-service-accounts) | queue-full | 407 |
| cp-02 | node-high (system-node-high) | time-out | 56 |

- All rejections came at 14:37–14:38, during remove-services and remove-configs. They were WATCH re-establishments (services 1,376, secrets 274) and 55 `PUT leases`.
- The `cilium` level had at most 3 requests executing and 3 queued (run 14: 42 executing, 247 queued during remove-services). It rejected nothing.

### 4. Other

- KCM (cp-02): 192–199 requests/s during creation, POST 88–311 ms, PUT about 200 ms. Its deployment queue reached 1,361 at 14:26:29, as kube-burner's creates came in, and the pods were still Ready 3 s after creation on average.
- Memory peaks: API server RSS 7.6 / 8.1 / 7.8 GiB (briefly, at 14:37–14:38 during the remove jobs); node 9.7 / 10.9 / 9.6 GiB.
- etcd: in-use space peaked at 630 MiB, inside the 900 MiB file. Slow applies rose by 1.5k on cp-01, 3.2k on cp-02 (leader) and 0.9k on cp-03.
- Sampled workers: 12 new sandboxes in 1.1–1.4 s. Cilium got no 429s. Bootstrap URLs: VIP on wk-01 and wk-801, `127.0.0.1` on the other three.
- Status codes: 11.7k 403 POSTs during namespace deletion and 6.1k 409 PUTs (KCM update conflicts) are expected, as in run 14.

## Recommendations

1. **Use `QPS=150 BURST=200` as the reference setting for this cluster.** It is the highest rate tested without errors, and it gives the same pod results as QPS 300. Compare read-job durations only between runs with the same QPS.
2. **Treat about 30 Services/s as the cluster's limit** with Kubernetes 1.36 and 8 vCPU control-plane nodes. QPS 150 is close to it (37/s, longest wait about 40 s against a 60 s timeout). Workloads that create Services faster will time out until one of these changes:
   - more vCPU on the control-plane nodes (82–95 % during creation);
   - Kubernetes v1.38, where ClusterIP allocation is concurrent (kubernetes/kubernetes#142758).
3. **Try keeping the etcd leader and the KCM leader on different nodes.** cp-02 had both in runs 14 and 15, and allocated Services at half the speed of the other servers. After the pre-run steps, check both leaders (`./defrag-etcd.sh` prints the etcd leader; the KCM leader is in the `kube-controller-manager` lease in kube-system). If they are on the same node, move the etcd leader with `etcdctl move-leader <member ID>` and compare cp-02's allocation time.
4. **Still open:**
   - the HAProxy and Keepalived logs after the next dropped connection (run 14, recommendation 3);
   - the kube-system `ByUser` FlowSchema and `apiserver_terminated_watchers_total` (run 13, recommendations 2 and 3). These only matter during removal now.
