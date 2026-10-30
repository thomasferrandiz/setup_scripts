# Run 16 — api-intensive, 4000 iterations, QPS 100 / burst 200, unbalanced start

Results: `results-api-intensive-20261030T114255Z-kHIKwA`. Compared with [run 15](./run_15_analysis.md), this run changed three things: **`ITERATIONS=4000`** (2000 before), **`QPS=100 BURST=200`** (150 / 200), and the cluster state at the start (see below).

The run did not finish. bash reported `Killed` for kube-burner (exit 137, SIGKILL) about 23 minutes into the patch job:

```
run.sh: line 519:  7092 Killed   kube-burner init -c "$workload.yml" ...
kube-burner failed (137).
```

Cluster state at start:
- **Unbalanced again:** goroutines **76k / 47k / 19k** on cp-01 / cp-02 / cp-03. API server RSS 7.7 / 5.5 / 2.8 GiB.
- **Two API servers had restarted since run 15:** their `process_cpu_seconds_total` was 94,697 s on cp-01, but only 3,473 s on cp-02 and **361 s on cp-03**. Run 15 had ended balanced (40k / 43k / 35k), and no rebalance was done after the restarts.
- **4,000 namespaces were left over from an earlier attempt.** kube-burner's pre-run cleanup logged `Deleting 4000 namespaces` at 11:43:14 and took **28m45s** (until 12:11:59). Stored objects went from 100.6k to 52.4k.
- **etcd only partly defragmented:** file 797 / 363 / 785 MiB on cp-01 / cp-02 / cp-03, 290 MiB in use. No leader change, 30 failed proposals on cp-02.
- **etcd leader cp-02, KCM leader cp-03.** They were on different nodes for the whole run, as run 15 recommended (3).

## Verdict

**kube-burner was OOM-killed on the bench VM, not by anything in the cluster.** `bench-net-01` has 1 vCPU and 2 GiB RAM. Holding 4,000 iterations of state was too much for it, along with the `kubectl` sampling processes that run.sh starts. The host started thrashing right after the patch job started. One `kubectl get --raw` sample took 22.5 minutes, and then the kernel killed kube-burner.

**Before it was killed, the creation job showed that the cluster could not keep up even at QPS 100, because cp-01 was overloaded.** That was the same failure mode as runs 12–13.

- **Service timeouts are back: 1,831** (all retried), even though kube-burner only sent about 25 Services/s, below the about 30/s limit measured in run 15. cp-01 held 76k goroutines and ran at 96 % CPU. From cp-01, etcd writes took 155–217 ms (7–38 ms from the other two servers), so it allocated only **2.7 ClusterIPs/s**.
- **Pods were slow again: Ready p99 151 s**, max 278 s, average 24 s (run 15: 5 / 6 / 3.0 s). Kubelets connected to cp-01 got 429s from the `system` priority level (5,914 rejections, the first time this level rejected at this scale).
- **The read job worked:** 17m18s with 0 errors. This matches run 15 scaled to twice as many objects at two-thirds of the QPS (5m39s × 2 × 1.5 = 17m).
- **Patch job:** 90 PATCHes failed with `http2: client connection force closed via ClientConn.Close` 6 s after it started. Then kube-burner stalled: only about 1,200 of 12,000 patches reached the API servers before the kill.
- **Not reached:** the remove jobs and the namespace cleanup. **The 4,000 `api-intensive-*` namespaces are still in the cluster.**

## Comparison

| | run 13 | run 14 | run 15 | **run 16** |
|---|---|---|---|---|
| Change | Cilium APF level; unbalanced | Rebalanced | QPS 150 / burst 200 | **4000 iterations, QPS 100; unbalanced** |
| Goroutines cp-01 / cp-02 / cp-03 | 31k / 6k / 78k | 39k / 42k / 36k | 40k / 43k / 35k | **76k / 47k / 19k** |
| etcd DB at start (total / in use) | 960 / 175 MiB | 900 / 143 MiB | 900 / 97 MiB | 797 (cp-02: 363) / 290 MiB |
| etcd leader / KCM leader | ? / cp-03 | cp-02 / cp-02 | cp-02 / cp-02 | cp-02 / cp-03 |
| kube-burner errors | 66 | 728 | 0 | **1,961: 1,831 Service timeouts (retried), 40 "already exists" on retry, 90 patches (connection closed); then killed** |
| Service create timeouts | 0 | 596 | 0 | **1,831** |
| Job start → all pods Ready | 4m03s | 1m55s | 2m00s | 7m18s (4,000 Deployments) |
| Pod Ready p99 / max / avg | 37 / 86 / 10 s | 5 / 5 / 3.0 s | 5 / 6 / 3.0 s | **151 / 278 / 24 s** |
| Initialized p99 | 5 s | 1 s | 1 s | 12 s |
| PodScheduled p99 | 4 s | 1.7 s | 1.6 s | 4.0 s |
| Read / patch | 2m52s / 3m10s | 2m53s / 2m46s | 5m39s / 2m58s | 17m18s / **killed** |
| APF rejections | 9,156 | 1,953 | 1,743 | **20,377** (all during creation, except 161) |
| 5xx | 16 | 596 | 1 | 1,831 (POST 504) |
| Peak node CPU cp-01 / cp-02 / cp-03 (creation) | 58 / 28 / 100 % | 76 / 94 / 76 % | 86 / 95 / 82 % | **96 / 92 / 52 %** |
| Namespace cleanup | 14m14s | 11m34s | 11m54s | not reached (pre-run cleanup of leftovers: 28m45s) |

## Findings

### 1. kube-burner ran out of memory on the bench VM

Timeline:

| Time | Event |
|---|---|
| 12:37:41 | Read job done. |
| 12:37:44–12:37:50 | Patch job starts a new pod-latency watcher and lists the 4,000 Deployments for each of its patch objects. |
| 12:37:56 | 90 PATCHes fail at once: `http2: client connection force closed via ClientConn.Close`. |
| 12:38:03 | Last kube-burner log line. |
| 12:38:24 | Last `kubectl top nodes` sample. The next step of the loop, `kubectl get --raw` for node metrics, doesn't return until **13:00:57**. |
| ≈13:00:57 | kube-burner gets SIGKILL. The remaining samples complete within 20 s, and run.sh exits with 137. |

- **The SIGKILL didn't come from run.sh.** Its trap sends SIGTERM, so it was the kernel OOM killer (or a manual kill). A 22-minute `kubectl` call followed by a quick recovery is what memory thrashing looks like on a VM with no swap.
- **The cluster was idle the whole time.** The API servers were at 0.9–1.4 cores. PATCH requests were only about 1,200 above the background rate over 23 minutes, so kube-burner was barely running. The bench VM was stuck, not the cluster.
- **kube-burner's memory scales with the iteration count.** It keeps pod-latency data for every pod it sees (4,000 from creation, and up to 12,000 more from the patch rollouts), the watcher's pod cache, and full lists of 4,000 objects for each patch object. On 2 GiB, that has to share memory with the `kubectl top nodes` and `kubectl get --raw` calls for 1,000 nodes that run.sh makes every 30 s. 2,000 iterations fit; 4,000 didn't.
- To confirm on bench-net-01: `journalctl -k | grep -iE 'out of memory|oom-kill'` should show `kube-burner` as the killed process at about 13:00.

**This may also explain the dropped connection seen in runs 11, 13 and 14.** `force closed via ClientConn.Close` is a close on the client side. client-go closes a connection when its HTTP/2 health-check ping gets no answer in time. Here it happened 6 s into the patch job, just as kube-burner's memory was climbing and the host was starting to stall. In runs 11, 13 and 14 it also happened at the start of a job, when kube-burner lists thousands of objects. A 1 vCPU / 2 GiB client that briefly stops reading frames would give exactly this error, with nothing in the API server or HAProxy logs. This is a hypothesis; the next run on a bigger VM will test it.

### 2. Service timeouts came back because cp-01 was overloaded, not because of the rate

kube-burner sent iterations 400 → 3,600 in 128 s (12:13:11 → 12:15:19), so about **25 Services/s**. That is below the about 30/s that run 15 measured with a balanced control plane.

| Server | Service POSTs (12:12–12:17) | ClusterIP allocation | API server → etcd create | Mean Service POST | Node CPU (peak) | 504s |
|---|---|---|---|---|---|---|
| cp-01 (76k goroutines) | 1,640 | **366–418 ms** (2.7/s) | **155–217 ms** | **33–34 s** | 7.7 cores (96 %) | 1,398 |
| cp-02 (etcd leader) | 3,547 | 58–65 ms (15–20/s) | 24–38 ms | 13–32 s | 7.4 cores (92 %) | 433 |
| cp-03 (19k goroutines, KCM leader) | 176 (from 12:15) | 50 ms | 7–36 ms | 1.7 s | 4.1 cores (52 %) | 0 |
| run 15, busiest window | 570–723 | 86–157 ms | 67–74 ms | 10–22 s | 5.5–6.0 cores | 0 |

- **etcd itself was fast.** fsync was 1–5 ms, backend commit 2–14 ms and the leader is on cp-02. The latency that cp-01 saw (155–217 ms) was time spent inside a CPU-starved API server, not in etcd. The other two servers saw 7–38 ms for the same etcd.
- Together the three servers allocated about 18–23 Services/s, which is fewer than the 25/s that kube-burner sent. cp-01's share queued for longer than the 60 s timeout. Each retry used a QPS token, so kube-burner's client-side throttling delays rose to 7 s, and the creates went on until 12:17:32. 40 retries found the Service already created by the first attempt.
- **cp-03 was mostly idle:** the HTTP/2 connections that kube-burner used for creation went to cp-01 and cp-02. cp-03 mostly served the KCM, which runs on the same node and talks to its local API server.
- **cp-02 with only the etcd leader allocated in 58–65 ms**, against 108–157 ms in runs 14–15 when it also held the KCM leader. That fits run 15's recommendation 3. But cp-02 also carried fewer node clients than cp-01 this time, so this run alone doesn't prove it.

### 3. The node agents behind cp-01 were throttled

| Server | Priority level (flow schema) | Reason | Rejections |
|---|---|---|---|
| cp-01 | workload-high (kube-system-service-accounts) | queue-full | 14,452 (161 during the pre-run cleanup) |
| cp-01 | **system (system-nodes)** | time-out | **5,914** |
| cp-01 | cilium (cilium) | time-out | 11 |

- All rejections were on cp-01, during creation (12:13–12:17).
- workload-high: re-established WATCHes on endpointslices (5.3k), secrets (4.8k), services (4.7k) and configmaps (1.0k), and about 40 each for the ingress controller's CRDs.
- system-nodes: kubelet requests, including `GET pods` (627), `PATCH pods` (status, 466), `POST/PATCH events` (1,160), `POST serviceaccounts` (token requests, 427), and `tokenreviews` / `subjectaccessreviews` (909).
- Sampled kubelets on cp-01: wk-401 and wk-801 had requests at 2–11 s and got 429s, and their pod start SLI was **104–111 s**. wk-601 was through the VIP and had 22 s. Cilium's API calls took 1.4–4.4 s on the same nodes (milliseconds in run 15), but the `cilium` level rejected almost nothing.
- The 62 `failed to get started of pod ... from event` warnings in kube-burner come from the rejected event writes.
- KCM (cp-03) was not the bottleneck: its deployment queue peaked at 796 and was empty by 12:16:40, with POST and PUT at 50–140 ms.

So this is the imbalance problem of runs 12–13 again: most node clients stay on one API server, and that server limits both Service creation and pod startup.

### 4. Other

- Memory peaks: API server RSS 8.2 / 5.8 / 3.8 GiB, node 69 / 57 / 47 %. All at 12:16–12:20, during creation.
- etcd: in-use space peaked at 538 MiB at 12:21, inside the file. Slow applies rose by 9.5k on cp-01, 61 on cp-02 (leader) and 0.9k on cp-03. Peer round-trip time rose to 30–90 ms during creation (3–5 ms before).
- Pre-run cleanup: kube-burner deleted the 4,000 leftover namespaces at about 2.3/s. That is slower than the end-of-run cleanup of runs 13–15 (2,000 in 11–14 min, about 2.8/s).
- Cilium bootstrap URLs: VIP on wk-601, `127.0.0.1` on the other four sampled nodes.

## Recommendations

1. **Clean up before the next run:** `kubectl delete ns -l kube-burner.io/job=api-intensive --wait=false`. Otherwise the next run's pre-run cleanup will take about 30 minutes again.
2. **Give the bench VM more memory before running 4,000 iterations.** In `main.tf`, raise `bench-net-01` to at least **4 vCPU / 8 GiB**. Check `journalctl -k` on bench-net-01 first to confirm the OOM kill. Until then, keep `ITERATIONS=2000`. Also consider adding the bench VM's own `free -m` and kube-burner RSS to run.sh's sampling loop, so the next failure is easy to spot.
3. **Re-test the dropped HTTP/2 connection on the bigger VM.** If `force closed via ClientConn.Close` stops happening, close run 14's recommendation 3 (HAProxy and Keepalived logs) and the open item in the overall summary.
4. **Rebalance before every run, and check that it worked.** Two API servers restarted between runs 15 and 16, and the goroutine split went from 40k / 43k / 35k to 76k / 47k / 19k. Run `./rebalance.sh` after any restart, and don't start until the three servers are within about 20 % of each other.
5. **Then repeat this test:** 4,000 iterations at `QPS=100 BURST=200`, balanced, with the etcd and KCM leaders on different nodes. That will show whether 25 Services/s is safe when the load is balanced, and whether cp-02 allocates faster without the KCM leader.
