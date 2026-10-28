# Run 09 — api-intensive, 2000 iterations, QPS 300 / burst 400, kubelet + Cilium metrics

Results: `results-api-intensive-20261027T170505Z-RXh3z6`. Benchmark settings are the same as run 08 (`ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true`, KCM qps 100 / burst 200 / 20 deployment and replicaset workers). All metrics were set to `required`, with **`NODE_SAMPLE_COUNT=100`** (workers bench-wk-01, 11, 21 … 991).

## Verdict

**This was the worst run so far. The new node metrics show why pods are slow: the Cilium agents are throttled by the API server.**

- **The sandbox delay is in Cilium.** On the sampled workers, during creation:
  - CNI `PUT /v1/endpoint` took **19 s on average**, and kubelet `RunPodSandbox` took **11–24 s on average**;
  - the Cilium agents' own API calls got **2,010 × 429**, 172 client errors and 61 × 500, with **3.2 s mean latency**.

  Once the API server calmed down, the same calls took 0.9 s and then 0.15 s. Cilium itself is not slow: endpoint regeneration averages 9–18 ms and the policy and BPF steps are about 0 ms.
- **APF rejected 46,668 requests** (18,359 in run 08):
  - **35,441** were `workload-high / kube-system-service-accounts` `queue-full`. Cilium, the Cilium operator and every KCM controller share this queue.
  - **10,337** were kubelet requests (`system` and `node-high`) that timed out in the queue.
- **etcd hit its apply backlog.**
  - **1,095 Service creates failed with `etcdserver: too many requests`** between 17:09:58 and 17:10:43. This error means etcd's applied index was more than 5,000 entries behind its committed index.
  - There were 392 failed proposals and ~10.8k slow applies.
  - The DB started at **831 MiB** (645 MiB at the end of run 08).
- **The API server on bench-cp-02 restarted at ~17:10:48.**
  - 82 Service creates got `dial tcp [::1]:6443: connect: connection refused`.
  - It had 8.1 GiB RSS on a node at 65 % memory. After the restart the node used 3.2 GiB.
  - kube-controller-manager on cp-02, which was the leader, restarted with it, and **cp-01 took over the lease**.
- **Results:**
  - Pod Ready p99 **168 s** (107 s in run 08). `Initialized` p99 is **80 s** (it was ~1 s before).
  - The job took 4m46s, because ~1,770 failed requests were retried.
  - The patch job took 3m44s (2m44s in run 08).
- **Sampling 100 nodes was too many.** 200 sequential proxy scrapes per cycle stretched the 30 s interval to **3.5–6.5 min**. There are only 8 samples per metric over the whole run, and the scrapes themselves added load to the API servers at the worst moment.

## Comparison

| | run 06 | run 07 | run 08 | **run 09** |
|---|---|---|---|---|
| KCM qps / burst / deploy+rs workers | 20 / 30 / 5 | 20 / 30 / 5 | 100 / 200 / 20 | 100 / 200 / 20 |
| Node metrics (kubelet + Cilium) | — | — | — | **100 nodes** |
| kube-burner errors | — | — | — | **3,546** |
| Service create timeouts | 0 | 248 | 107 | **~595** |
| Service creates failing with `etcdserver: too many requests` | 0 | 0 | 0 | **1,095** |
| Service creates failing with `connection refused` | 0 | 0 | 0 | **82** |
| Job start → all pods Ready | 8m17s | 8m26s | 3m23s | ~3.5–4 min (job 4m46s) |
| Pod Ready p99 / max | — | 7 s / 11 s | 107 s / 138 s | **168 s / 189 s** |
| Initialized p99 | — | — | ~1 s | **80 s** |
| PodScheduled p99 | — | — | 1.3 s | 2.1 s |
| Read / patch | 2m48s / 12m28s | 2m48s / 12m28s | 2m49s / 2m44s | 3m0s / **3m44s** |
| remove-deployments / services / configs | 12 / 13 / 30 s | 11 / 15 / 35 s | 17 / 20 / 50 s | 19 / 22 / 25 s |
| APF rejections | 3,902 | 4,826 | 18,359 | **46,668** |
| 5xx | 10 | 99 | ~770 | **~1,407** |
| etcd slow applies (Δ, all members) | 3,818 | 5,184 | 8,246 | 10,788 |
| etcd failed proposals | 0 | 1 | 302 | **392** |
| etcd DB size (start → end) | ~500 MiB | 478 MiB | → 645 MiB | **831 → 863 MiB** |
| Control-plane restarts | — | — | KCM cp-03 | **API server + KCM on cp-02** |
| Namespace cleanup | 12m46s | 12m49s | 14m09s | 12m58s |

## Findings

### 1. Cilium waits on the API server, and that is the sandbox delay

Deltas summed over the 100 sampled workers. Each window is one scrape cycle of 3.5–6.5 min.

| Window | Cilium `PUT /v1/endpoint` (mean) | Cilium k8s calls: 200 / 201 / 404 / **429** / error / 500 | Cilium k8s latency (mean) | kubelet `RunPodSandbox` (mean) | kubelet 429 / 5xx |
|---|---|---|---|---|---|
| creation (→17:12/17:14) | **18.9 s** (n=197, 7 failed) | 3,663 / 379 / 194 / **2,010** / 172 / 61 | **3.2 s** | 11.2 s (n=91) | 767 / 46 |
| read + patch (→17:17/17:20) | 0.9 s (n=110) | 1,322 / 111 / 110 / 1 / 0 / 1 | 94 ms | 24.4 s (n=125, 7 errors) | 610 / 45 |
| patch end / delete (→17:23/17:25) | 0.15 s (n=86) | 2,081 / 86 / 86 / 168 / 0 / 0 | 163 ms | 0.8 s (n=177) | 23 / 0 |
| idle | — | ~1,000 × 200 | 3–12 ms | — | 0 |

- Each pod creates a CiliumEndpoint: a `GET` that returns 404, then a `POST` that returns 201, hence the matching 404 and 201 counts.
  - When the agent's calls are queued or rejected by APF, the CNI ADD call blocks.
  - 7 endpoint creates failed. These are the 7 `RunPodSandbox` errors. The endpoint-create limiter's `wait_duration_seconds{value="max"}` reads 60 s, but run 10 shows it stays at 60 s even when the cluster is idle. It is a lifetime maximum, not the wait during this run.
- The second window's long `RunPodSandbox` mean while Cilium's own time was already 0.9 s comes from sandboxes that started in the first window and finished in the second. Kubelet's own API calls also got **1,426 × 429** (kubelet status updates are in `system` / `node-high`), which delays `Initialized` and `Ready` status reporting.
- Cilium's internals are fast:
  - regeneration totals are 9–18 ms;
  - waiting for locks, waiting for policy computation and BPF compilation are all ~0 ms;
  - nearly every endpoint was `ready`, with only 1 seen in `waiting-for-identity`.
- No container image pulls happened during the run (`pull_image` n=0), so image pulls are not a factor.

### 2. APF: the shared `kube-system-service-accounts` queue overflows

| Member | Priority level / flow schema | Reason | Rejections |
|---|---|---|---|
| cp-01 | workload-high / kube-system-service-accounts | queue-full | 24,742 |
| cp-03 | workload-high / kube-system-service-accounts | queue-full | 9,914 |
| cp-03 | system / system-nodes | time-out | 5,216 |
| cp-03 | node-high / system-node-high | time-out | 3,743 |
| cp-01 | node-high / system-node-high | time-out | 945 |
| cp-03 | workload-high / kube-system-service-accounts | time-out | 890 |
| cp-01 | workload-high / kube-system-service-accounts | time-out | 785 |
| cp-01 | system / system-nodes | time-out | 433 |

- The Cilium agents (1,000), the Cilium operator and all KCM controllers, which now run at 100 qps, compete in one `workload-high` queue.
- cp-02 is missing from the table because its counters reset when it restarted. Its rejections from before 17:10:48 are lost.
- 5xx: 681 `GET 500` and ~726 `504` (POST 422, PUT 181, PATCH 121, DELETE 2), mostly on cp-03.

### 3. etcd apply backlog and the DB size

- `etcdserver: too many requests` (1,095 Service creates, 17:09:58–17:10:43). The Service IP allocator writes an `IPAddress` object through the local API server (`[::1]:6443`). etcd rejected these writes because its apply loop was more than 5,000 entries behind.
- Failed proposals at 17:08 → 17:14: cp-01 +1, cp-02 +288, cp-03 +103. Pending proposals peaked at 31 on the leader (cp-01).
- WAL fsync and backend-commit p99 stayed at 4–64 ms, so the disks are not the problem. The bottleneck is apply throughput: the volume of writes and a large DB.
- At baseline the DB was **831 MiB with 823 MiB in use**, and the API server had 34,842 objects in storage. Most of the space was old revisions from run 08 that had not yet been compacted. Compaction brought the in-use size down to 165 MiB by the end, but the file grew to 863 MiB. Without a defrag, the DB keeps growing: 478 → 645 → 863 MiB over three runs.

### 4. Restart of the cp-02 API server

- The API server's `process_cpu_seconds_total` went from 194,475 s to 48 s; the restart happened at **~17:10:48**, when the 82 `connection refused` errors occurred.
- The KCM on cp-02 restarted too: its CPU counter went from 580 s to 0.7 s. The KCM lease moved to cp-01, and cp-01's API server then did most of the work (up to 37 % node CPU, 7.9 GiB RSS).
- etcd on cp-02 did not restart.
- At baseline the cp-02 API server already had **8.1 GiB RSS**, and the node was at 65 % memory. The memory drop after the restart (10.4 → 3.2 GiB used) points to an **OOM kill** or a kubelet-triggered restart of the static pod. To confirm, check `journalctl -k | grep -i oom` and `crictl ps -a` on bench-cp-02.
- KCM on cp-01 and cp-03 had only 7–11 s of CPU at baseline. They had restarted shortly before the run and were not the leader.

### 5. Sampling overhead and resolution

- `NODE_SAMPLE_COUNT=100` means 100 kubelet scrapes and 100 Cilium scrapes through the API server proxy per cycle, run sequentially.
- Sample intervals were 337, 261, 384, 216, 214, 212 and 209 s instead of 30 s, which affected every TSV (`node-usage.txt` has only 6 snapshots). As a result:
  - this run has no per-minute view of creation and patching;
  - etcd, KCM and API server events between 17:08:14 and 17:14:34 fall into a single window;
  - `kubelet-errors.log` has 16 client timeouts (for example bench-wk-461 at 17:08:14), all caused by the overloaded API servers.
- The proxy scrapes also used part of the overloaded API servers' capacity, so the measurement itself made the run slower.

## Recommendations

1. **Lower `NODE_SAMPLE_COUNT` to 5–10** (default 5). If more nodes are needed, run the node scrapes in parallel, with a bounded number of concurrent scrapes and in the background, so that the 30 s cycle is not stretched.
2. **Give the Cilium agents their own APF priority level.** This is run 08's recommendation 4, and this run now shows it is the main cause of slow pod startup.
   - Create a `FlowSchema` matching the `cilium` and `cilium-operator` service accounts in `kube-system`, with precedence below 800 so it is evaluated before `kube-system-service-accounts`.
   - Point it at a dedicated `PriorityLevelConfiguration` with its own concurrency shares, for example 40–80, and `queueLengthLimit` 128 or more.
   - Do the same for kube-controller-manager if its controllers keep filling the queue.
3. **Defragment etcd and confirm the cluster has recovered before each run.**
   - Run `etcdctl defrag` on each member, one at a time. The DB is 863 MiB with 165 MiB in use.
   - Wait for compaction after the previous run's cleanup.
   - Start the next run only after a check passes: DB in use < 300 MiB and all KCM/API server processes stable.
4. **Lower kube-burner to QPS 200 / burst 300** (run 08's recommendation 3) to keep etcd's apply loop under the 5,000-entry limit.
5. **Investigate memory on the control plane.**
   - Confirm the OOM on bench-cp-02.
   - The API servers use 5–8 GiB RSS on 16 GiB nodes that also run etcd, KCM and scheduler. Consider 32 GiB control-plane VMs, or reducing API server cache pressure.
6. **Increase the KCM leader-election timeouts** (`leader-elect-lease-duration=60s`, `leader-elect-renew-deadline=40s`). This is still pending from run 08. In this run the KCM restart came from the API server restart rather than a lost lease.
