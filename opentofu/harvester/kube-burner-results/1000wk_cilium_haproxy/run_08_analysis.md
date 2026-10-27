# Run 08 — api-intensive, 2000 iterations, QPS 300 / burst 400, KCM limits raised

Results: `results-api-intensive-20261027T154325Z-2IL6y6`. Benchmark settings are the same as run 07 (`ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true ETCD_METRICS=required KCM_METRICS=required`).

The cluster change is in kube-controller-manager:

| Setting | Before (default) | This run |
|---|---|---|
| `kube-api-qps` | 20 | 100 |
| `kube-api-burst` | 30 | 200 |
| `concurrent-deployment-syncs` | 5 | 20 |
| `concurrent-replicaset-syncs` | 5 | 20 |

## Verdict

**The KCM change removed the 8-minute bottleneck, but the load now lands on the API servers and etcd, which are overloaded.**

- **Faster:**
  - Job start → Ready: **3m23s** (8m26s in run 07).
  - Patch job: **2m44s** (12m28s in every previous run).
  - The leader's client-side rate-limiter wait is down to 20–60 ms per request, from ~225 ms. The `deployment` queue drains in about a minute instead of sitting at ~2,000 for 6 minutes.
- **Worse:**
  - APF rejected **18,359** requests (~4–5k before). Almost all are `workload-high / kube-system-service-accounts` `queue-full`, now also during creation. There are also **1,690 `node-high` time-outs**, which are kubelet requests.
  - **~770 5xx**: 223 `GET 500`, 176 `POST 504`, 201 `PUT 504`, 167 `PATCH 504`.
  - etcd had **302 failed proposals** (≤1 before), all at 15:54–15:55.
  - The **kube-controller-manager leader (cp-03) lost its lease and restarted** at ~15:54:30, during `remove-configs`. cp-02 took over.
  - 107 Service creates timed out and were retried, about half of run 07's 248.
- **Bottleneck moved to the nodes:** Pod Ready p99 is **107 s** (7 s in run 07). Pods are scheduled in ~1 s but wait up to 138 s for a sandbox (`PodReadyToStartContainers`). All 2,000 pods now reach the nodes within a minute instead of trickling in at ~4/s, so pod startup (CNI/Cilium, kubelet) is the slow step.

## Comparison

| | run 05 | run 06 | run 07 | **run 08** |
|---|---|---|---|---|
| KCM qps / burst / deploy+rs workers | 20 / 30 / 5 | 20 / 30 / 5 | 20 / 30 / 5 | **100 / 200 / 20** |
| Service create timeouts | 0 | 0 | 248 | 107 |
| Job start → Ready | 8m13s | 8m17s | 8m26s | **3m23s** |
| Pod Ready p99 / max | — | — | 7 s / 11 s | **107 s / 138 s** |
| PodScheduled p99 | — | — | — | 1.3 s |
| Read / patch | 2m49s / 12m28s | 2m48s / 12m28s | 2m48s / 12m28s | 2m49s / **2m44s** |
| remove-deployments / services / configs | 11 / 13 / 23 s | 12 / 13 / 30 s | 11 / 15 / 35 s | 17 / 20 / 50 s |
| Control-plane CPU peak | 91% | ~90% | 93% / 95% | 94% cp-01, **98% cp-03** |
| APF rejections | 3,141 | 3,902 | 4,826 | **18,359** |
| 5xx | 0 | 10 | 99 | **~770** |
| etcd slow applies (cp-01 / 02 / 03) | 1,669 | 675 / 728 / 2,415 | 702 / 3,795 / 687 | 826 / 1,799 / **5,621** |
| etcd failed proposals | 0 | 0 | 1 | **302** |
| etcd DB size | → ~500 MiB | → ~500 MiB | → 478 MiB | 109–112 → **645 MiB** (168 MiB in use) |
| KCM leader restarts | — | — | 0 | **1** (cp-03, 15:54) |
| KCM rate-limiter wait (leader, busy phase) | — | — | ~225 ms | 20–60 ms |
| Namespace cleanup | 12m57s | 12m46s | 12m49s | 14m09s |

## Findings

### 1. KCM is no longer the bottleneck

These are the values on the leader, cp-03 until 15:54.

| window | rate-limiter wait s/s | mean wait ms | requests/s | 409/s | `deployment` depth | `replicaset` depth | deployment queue wait |
|---|---|---|---|---|---|---|---|
| 15:44:35 | 0.1 | 0.6 | 138 | 19 | 1,994 | 385 | 21 s |
| 15:45:07 | 13.8 | 50 | 280 | 32 | 1,947 | 796 | 39 s |
| 15:45:40 | 12.1 | 61 | 201 | 8.5 | 0 | 0 | 24 s |
| patch, 15:51:28 – 15:53:39 | 0.6 – 9 | 3 – 54 | 170 – 280 | 0 – 30 | 1,994 → 0 | up to 1,738 | 10 – 55 s |

- The deployment backlog cleared in about one minute for both creation and patching. KCM throughput went from a flat ~52 requests/s to 200–280 requests/s.
- There is still some client-side wait (12–14 s/s at the peak), so `kube-api-qps=100` is now about the right limit, not far too high.
- `409` conflicts went up to ~30/s because 20 workers now race on the same Deployment status updates.

### 2. The load moved to the API servers (APF rejections and 5xx)

- Rejections by priority level:
  - **`workload-high / kube-system-service-accounts` `queue-full`: 15,931** (cp-03 8,347, cp-02 6,531, cp-01 1,053), plus 738 `time-out`. That flow schema matches every service account in `kube-system`. That includes KCM's per-controller accounts (RKE2 uses `use-service-account-credentials`) as well as the Cilium agents and operator, so they now compete in the same queues.
  - **`node-high / system-node-high` `time-out`: 1,690** (cp-03 1,246, cp-01 444). These are kubelet requests that waited too long in APF, which had not happened in earlier runs.
- When the rejections happened:
  - creation wait (15:44–15:46): ~4,000 `workload-high`, 230 `node-high`, 107 `POST 504`, 63 `GET 500`;
  - delete phase (15:54–15:55): ~12,500 `workload-high`, 1,460 `node-high`, and the remaining ~600 5xx.
- The traffic is uneven. The KCM leader talks to its local API server, so cp-03 served most of the controller traffic (POST up to 264/s, PUT 226/s) and reached 98% node CPU. cp-02 was mostly idle during the wait phase.

### 3. The delete phase overloads etcd, and the KCM leader is lost

- The `remove-*` jobs ran while the now much faster garbage collector deleted pods and ReplicaSets. In earlier runs those deletes were spread out by the throttling.
- What happened at 15:54:
  - the `DELETE` mean reached 1.8 s on cp-03;
  - etcd recorded 3,510 slow applies in 40 s and **302 failed proposals** (cp-01 208, cp-03 91, cp-02 3), with no leader change;
  - 9,174 APF rejections in that minute.
- The KCM on cp-03 could not renew its leader lease in time and exited (counters reset to 0 between 15:54:11 and 15:55:05). cp-02 took over at 15:55:05 and finished garbage collection and namespace cleanup.
- Namespace cleanup took 14m09s. The `namespace` queue stays at ~1,960 while the leader sends ~420 requests/s with no rate-limiter wait. Cleanup is therefore not throttled by KCM; the time goes into deleting the contents of each namespace.

### 4. The new bottleneck is pod startup on the nodes

- Ready p99 107 s, avg 27.6 s. Patched pods show the same pattern (p99 104 s).
- PodScheduled p99 is 1.3 s and Initialized 1 s, so the scheduler is fine.
- The time is spent between scheduling and `PodReadyToStartContainers`, i.e. creating the sandbox: the CNI ADD through Cilium, which allocates a security identity per namespace and creates a CiliumEndpoint.
- The Cilium agents use the same `kube-system-service-accounts` flow schema that was rejecting requests at the time. That would explain part of the delay, but it is a hypothesis: this run has no Cilium or kubelet metrics.
- The control-plane VMs are saturated (94–98%), while workers sit at ~5–10% CPU.

### 5. etcd

- The DB grew to 645 MiB (168 MiB in use), more than in previous runs. Defragment before the next run.
- cp-03 had the most slow applies (5,621) because it is the busiest API server.

## Recommendations

1. **Keep the KCM changes.** They cut the time to Ready by 60% and the patch job by 78%.
2. **Spread the load across the API servers and protect the leader:**
   - Raise KCM `leader-elect-lease-duration=60s` / `leader-elect-renew-deadline=40s` (defaults 15 s / 10 s), so that an overloaded API server doesn't make the KCM leader restart. Do the same for kube-scheduler.
   - Alternatively, compare with `kube-api-qps=50` / `kube-api-burst=100`. Expect Ready in ~4–5 min, with much less pressure on cp-03 and etcd.
3. **Reduce the kube-burner create rate to QPS 200 / burst 300.** It still causes Service create timeouts, and the creates now overlap with KCM's own burst.
4. **APF:** if `workload-high` rejections persist, add a FlowSchema that sends the Cilium service accounts (`cilium`, `cilium-operator`) to their own priority level. Alternatively, raise `workload-high`'s `nominalConcurrencyShares`. Either way, KCM and the CNI stop starving each other.
5. **Investigate pod sandbox latency:**
   - check a slow worker's `cilium-agent` logs and `cilium_endpoint_regeneration_time_stats_seconds`;
   - check `cilium_identity` allocation and kubelet's `kubelet_run_podsandbox_duration_seconds`.

   Consider adding Cilium metrics sampling to `run.sh`.
6. Defragment etcd between runs (645 MiB this time).
