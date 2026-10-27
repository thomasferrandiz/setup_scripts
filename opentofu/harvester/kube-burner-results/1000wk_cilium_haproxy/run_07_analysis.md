# Run 07 — api-intensive, 2000 iterations, QPS 300 / burst 400, KCM metrics

Results: `results-api-intensive-20261027T133536Z-GXaT2W`. Settings are the same as runs 04–06 (`ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true ETCD_METRICS=required`), plus `KCM_METRICS=required`. This is the first run with kube-controller-manager metrics.

## Verdict

**The ~8 minutes to all Deployments Ready are caused by kube-controller-manager throttling itself on the client side. The API server and etcd are not the bottleneck during that phase.**

The KCM leader (cp-01):
- Spends **~11.5 s of rate-limiter wait per second** for the whole wait phase. Each request waits **~225 ms** for a client-side token (PUT ~190 ms, POST ~290 ms).
- Sends a steady **~52 requests/s** to the API server. That is about what the per-controller default of `kube-api-qps=20` allows, with the deployment and replicaset controllers each at their limit.
- Has its `deployment` work queue stuck at **~1,995 items** for 6 minutes. The time an item spends queued grows linearly, up to **~320 s**.

The work drains in this order:
1. The `replicaset` queue reaches 0 at 13:42:39.
2. The client starts returning errors, and Deployments go Ready in bulk (795 at 13:42, 998 at 13:43).

The patch phase (12m28s in every run) shows the same throttling signature. Namespace cleanup does too for its first ~7 minutes (namespace and garbage-collector controllers).

The create burst also reproduced run 04's failure: **248 Service creates timed out** and were retried successfully, with **98 `POST 504`** on cp-02. kube-burner logged 496 `level=error` lines (one timeout plus one retry for each object).

## Comparison

| | run 04 | run 05 | run 06 | **run 07** |
|---|---|---|---|---|
| Service create timeouts / POST 504 | 119 | 0 | 0 | **248 / 98** |
| Worst POST mean latency (create burst) | ~5 s | 4.9 s | 6.3 s (cp-03) | 4.2 s (cp-02) |
| Control-plane CPU peak | ~90% | 91% | ~90% | 93% cp-01 / 95% cp-02 |
| Job start → Ready | 8m19s | 8m13s | 8m17s | 8m26s |
| Pod Ready p99 / max | — | — | — | 7 s / 11 s |
| Read / patch | 2m50s / 12m28s | 2m49s / 12m28s | 2m48s / 12m28s | 2m48s / 12m28s |
| remove-deployments / services / configs | 12 / 15 / 30 s | 11 / 13 / 23 s | 12 / 13 / 30 s | 11 / 15 / 35 s |
| APF rejections | 5,164 | 3,141 | 3,902 | 4,826 |
| etcd slow applies (cp-01 / 02 / 03) | 2,159 (1 failed) | 1,669 | 675 / 728 / 2,415 | 702 / **3,795** / 687 (1 failed) |
| etcd DB size | ~110 → 500 MiB | idem | idem | 92–113 → 478 MiB (122 MiB in use) |
| Namespace cleanup | 12m59s | 12m57s | 12m46s | 12m49s |
| KCM rate-limiter wait (leader) | — | — | — | **~11.5 s/s, ~225 ms per request** |

## Findings

### 1. KCM client-side throttling (new, confirmed)

These are the leader's (cp-01) values during the wait for Ready. cp-02 and cp-03 are standbys and show no activity.

| window | rate-limiter wait s/s | mean wait ms | requests/s | 409/s | `deployment` queue depth | `replicaset` queue depth | deployment queue wait (mean) |
|---|---|---|---|---|---|---|---|
| 13:36:51 | 16.7 | 148 | 113 | 5.3 | 1,998 | 130 | 27 s |
| 13:37:23 | 22.4 | 187 | 120 | 5.3 | 1,996 | 136 | 59 s |
| 13:38:58 – 13:42:08 | 11.4–11.9 | ~225 | ~52 | ~5.4 | ~1,995 | 111 → 48 | 148 → 324 s |
| 13:42:39 | 8.1 | 183 | 44 | 0.7 | 1,955 | 0 | 314 s |
| 13:44:13 | 4.3 | 205 | 21 | 0 | 0 | 0 | 68 s |

- The flat ~52 requests/s together with a mean wait of hundreds of ms is the textbook signature of a client-side token bucket. The API server answers these requests in tens of ms (cp-01 PUT mean 9–38 ms).
- The ~5.4 `409`/s observed in runs 04–06 are the deployment controller's own status-update conflicts. They waste part of an already throttled budget, and they stop when the replicaset queue drains.
- KCM CPU stays at 0.1–0.2 cores, so KCM is idle while it waits for tokens.
- Patch job (13:48–14:00): same pattern, with ~11.6 s/s of wait, ~52 requests/s and the `deployment` queue back at ~2,000 for 11 minutes. This is why the patch job always takes exactly 12m28s.
- Cleanup (14:01–14:07):
  - The garbage collector and namespace controllers run at ~20 s/s of wait, then the garbage-collector `attempt_to_delete` queue (5,000+) drains.
  - After 14:08 the wait is ~0.5 s/s, yet the `namespace` queue still holds 1,100–1,900 items. The remaining ~6 minutes of cleanup are therefore not client throttling; they come from the namespace finalisation path (the ~12k `POST 403` seen before).

### 2. Create burst: Service timeouts are back

- 248 Service creates in namespaces ~113–197 hit the API server's request timeout between 13:36:39 and 13:36:56. kube-burner retried them all and they succeeded (`already exists` 0).
- cp-02 bore the brunt:
  - POST mean 4.0–4.2 s;
  - 363 mutating requests in flight;
  - 168 requests in APF queues;
  - 98 `POST 504`;
  - 6 cores of API server CPU.
- cp-01 also reached 1.7 s POST mean and 93% node CPU.
- Whether a run crosses the timeout is a coin toss at QPS 300: 2 runs out of 4 did.

### 3. etcd: the slow member moves

- 3,795 of the 5,184 slow applies are on cp-02 this time. In run 06 the slow member was cp-03 (2,415). There is 1 failed proposal and no leader change; cp-01 is the etcd leader.
- The hot spot follows whichever API server takes the most load during the burst. Here that was cp-02, which also had the 504s. Since it moves from run to run, it does not point to a single bad disk.
- The DB grew to 478 MiB with 122 MiB in use. Defragment between runs.

### 4. Delete phase

- APF rejected 4,826 requests, all of them `kube-system-service-accounts` WATCH 429s at the start of the delete phase, as in previous runs.
- cp-02 peaked at 95% CPU at 14:02:28, during namespace deletion.

## Recommendations

1. **Raise KCM client limits** (`server-cloud-config.yml`, `kube-controller-manager-arg`), e.g. `kube-api-qps=100` and `kube-api-burst=200`.
   - The API server has headroom during the wait phase, and the cluster has 1,000 nodes, where the default of 20 is far too low.
   - Also consider `concurrent-deployment-syncs=20` and `concurrent-replicaset-syncs=20`. They only help once the QPS limit is raised.
   - Re-run with the same settings. Expected result: Ready in ~1–2 min instead of ~8 min, a much shorter patch job, and a non-zero `rest_client_rate_limiter_duration_seconds` that stays in the low ms.
2. **Reduce the create burst** so Service creates stop timing out, e.g. QPS 200 / burst 300. Alternatively accept the retries, but then don't count the run as error-free.
3. Namespace cleanup is limited by something other than KCM throttling after the first ~7 min. Look at namespace-controller `workqueue_queue_duration` and at the `POST 403` sources if cleanup time matters.
4. Keep defragmenting etcd between runs.
