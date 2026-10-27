# haproxy + keepalived run 02: api-intensive, 2000 iterations

Run `results-api-intensive-20261026T113407Z` used the same cluster as run 01, after an etcd defrag. Settings, from `parameters.env`: `ITERATIONS=2000 QPS=200 BURST=400 ETCD_METRICS=required`, with defaults for the rest. Run 01 used the default `BURST` (= `QPS`).

## Verdict

The run was **clean again**: kube-burner logged 0 errors, the API servers returned no 5xx, etcd had no failed proposals and no leader changes, and all 1003 nodes were Ready at the end. The pod-start regression from run 01 is gone, which confirms it came from the first image pull on new nodes.

## Comparison

| | Run 4 (kube-vip) | haproxy 01 | haproxy 02 |
|---|---|---|---|
| BURST | 200 | 200 (default) | **400** |
| kube-burner errors | 296 | 0 | **0** |
| Create loop (2000 iterations) | ~128 s | ~92 s | ~100 s |
| POST latency during create | 88 → 939 ms | 23 – 59 ms | 20 – 105 ms |
| Pod Ready p99 (create) | 3 s | 23 s | **3 s** |
| ContainersStarted p99 (patch) | – | 19.9 s | **3.5 s** |
| remove-deployments / remove-services | 14 s / 50 s | 14 s / 14 s | 13 s / 16 s |
| Delete burst: in-flight mutating / queued (max) | 506 / 180 | ~10 / 0 | **254 / 485** |
| Delete burst: mean DELETE latency (30 s window) | up to 60 s timeouts | 0.5 – 1.1 s | 0.6 – 0.8 s |
| APF rejections | 3,152 (incl. heartbeats) | 8,877 | **3,619** |
| API 5xx | ~750 | 0 | 0 |
| etcd slow applies / failed proposals | 3,294 / 232 | 1,482 / 0 | 2,185 / 0 |
| etcd database file (start → end) | 113 → 469 MiB | 154 → 513 MiB | **111** → 494 MiB |
| Namespace cleanup | 14m09s | 12m48s | 12m49s |

Read (4m10s) and patch (12m37s) took the same time in all three runs.

## Findings

### Pod start time is back to normal
- During create, PodScheduled p99 was 1.0 s, PodReadyToStartContainers p99 3 s and ContainersStarted p99 **3.6 s** (23 s in run 01).
- The patch phase is also back to normal, at 3.5 s against 19.9 s in run 01.
- The images were already cached on the nodes from run 01, so the slow starts in run 01 came from the first image pull, not from the control plane. **Every new cluster needs a warm-up run** (or `preLoadImages: true`) before its pod-latency numbers are comparable.

### BURST=400 doesn't speed up creation, but makes delete bursts sharper
- **Creation rate is unchanged:** 200 iterations every ~10 s in both runs. The steady rate is set by `QPS`, and `BURST` only allows short spikes. API latency stayed low and nothing was queued during create, so the next step to go faster is raising `QPS`.
- **Deletes now arrive in a spike:** at the start of the delete phase (11:59:46–12:00:56), kube-burner sent up to 400 requests at once. Each API server peaked at 200–254 in-flight mutating requests, with up to 371 (cp-02) and 485 (cp-03) requests waiting in APF queues. In run 01 there were about 10 in flight and nothing queued.
- **That spike was absorbed:** no 5xx, no timeouts, and deletes averaged 0.6–0.8 s. Control-plane node CPU peaked at 82% (cp-01) and 79% (cp-03), with cp-02 at 64%.
- **Fewer rejections:** APF rejections fell to 3.6k. They are all again WATCH requests from `kube-system-service-accounts` (`workload-high`), most likely Cilium agents re-establishing watches. Node heartbeats were never throttled.

### kube-burner itself sticks to one API server
- kube-burner keeps one HTTP/2 connection, so all of its traffic goes to whichever server haproxy picked when it connected. In run 01 its LISTs went to cp-02 (78k), in run 02 to cp-03 (75k), and the other servers each saw fewer than 100.
- **cp-03 did more work this run:** 4.1k CPU-seconds, against 3.0k on cp-02 and 3.6k on cp-01. During create its POST latency (41–105 ms) was higher than on the other two (~20 ms), and its etcd member logged the most slow applies (1,401).
- **This is a property of the benchmark client, not of real traffic.** Thousands of kubelets and agents spread out naturally. To compare runs, note which server kube-burner landed on: the one with the most `LIST` requests.

### Namespace cleanup is unchanged
- Cleanup took 12m49s and again went almost entirely through cp-01 (158k DELETEs, 550–680 req/s). That is the kube-controller-manager leader, which uses its local API server.
- The `POST 403` errors also came back (13.2k, mostly in the first 3 minutes of cleanup), consistent with creates rejected in namespaces being deleted.

### etcd
- **Defrag worked:** the run started at 111 MiB (110 MiB in use), against 154 MiB in run 01.
- **Database file:** grew back to 494 MiB, with 184 MiB in use at the end. Defragment again before the next run.
- **Disk:** fsync p99 8 ms and commit p99 16 ms over the run. In the worst 30 s window, they reached 32 ms and 64 ms.
- **Leader:** cp-01 for the whole run, ≤ 0.73 CPU cores. Pending proposals peaked at 36 during the delete burst, with no apply backlog.
- **API servers weren't restarted between runs:** their memory at the start (5.5 / 4.5 / 5.5 GiB) was higher than in run 01 (3.6–4.5 GiB). Goroutines were the same (36k / 35k / 46k).

## Recommendations
1. **Keep the current setup:** two clean runs in a row, and pod latency is back to the run 4 level.
2. **Measure create throughput by raising `QPS`** (for example 300, then 400), not `BURST`. The API servers still had headroom during create.
3. **Use `BURST=QPS` for the delete phases,** or give those jobs a lower QPS, if you want to avoid the in-flight and queue spike. It caused no errors at 400, but it is the closest the control plane came to saturation in this run.
4. **Do a warm-up run on every new cluster** before comparing pod latency.
5. **Defragment etcd** and optionally restart the API servers between runs, so each run starts from the same state.
