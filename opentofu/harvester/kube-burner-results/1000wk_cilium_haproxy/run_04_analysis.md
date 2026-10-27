# haproxy + keepalived run 04: api-intensive with pre-created namespaces

Run `results-api-intensive-20261026T151104Z` used the same cluster and etcd was defragmented first. Settings, from `parameters.env`: `ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true ETCD_METRICS=required`. The only change from run 03 is `preCreateNamespaces`.

## Verdict

**Object creation is now limited by QPS, and the control plane started to struggle.** The 8000 objects were created in ~27 s instead of ~90 s. During that burst:
- 119 Service creates timed out on the server after 34 s, and kube-burner retried them successfully;
- the control-plane nodes peaked at 81–92% CPU;
- POST latency averaged up to 5.4 s;
- etcd stayed healthy, apart from one failed proposal.

kube-burner exits 3 for this run because of the logged errors. Every object was created in the end.

**The total time to get all Deployments Ready did not change: ~8 minutes in every run.** Something downstream of the API servers processes about 4 Deployments/s. The most likely cause is kube-controller-manager's client-side rate limit (see below).

## Comparison

| | haproxy 02 | haproxy 03 | haproxy 04 |
|---|---|---|---|
| QPS / BURST / pre-create | 200 / 400 / no | 300 / 400 / no | 300 / 400 / **yes** |
| kube-burner errors / API 5xx | 0 / 0 | 0 / 0 | **119 Service timeouts (retried)** / 8 |
| Namespace creation | inside loop | inside loop | ~18 s (2000, one at a time) |
| Object creation (8000 objects) | ~100 s | ~90 s | **~27 s (~300/s)** |
| Create phase: APF queued / mean POST latency, worst 30 s window | – | 0 / 74 ms | 0 / **5.4 s** (352 mutating requests in flight) |
| Create phase: control-plane node CPU peak | – | 84% | **92%** (cp-01) |
| Job start → all Deployments Ready | 8m00s | 7m59s | 8m19s |
| Pod Ready p99 / max | 3 / 6 s | 3 / 5 s | 4 / 6 s |
| Read / patch | 4m10s / 12m37s | 2m48s / 12m28s | 2m50s / 12m28s |
| remove-deployments / services / configs | 13 / 16 / 29 s | 11 / 11 / 21 s | 12 / 15 / 30 s |
| Delete burst: queued / worst mean DELETE | 485 / 0.8 s | 415 / 0.8 s | **0** / 0.6 s |
| APF rejections (`kube-system-service-accounts`) | 3,619 | 3,595 | 5,164 |
| etcd slow applies / failed proposals / max apply lag | 2,185 / 0 / 2 | 2,669 / 0 / 307 | 2,159 / **1** / 2 |
| etcd fsync / commit p99 (whole run) | 8 / 16 ms | 8 / 16 ms | 8 / 16 ms |
| etcd database file (start → end) | 111 → 494 MiB | 110 → 512 MiB | 110 → 500 MiB |
| Namespace cleanup | 12m49s | 12m59s | 12m59s |

## Findings

### Pre-creating namespaces worked, and corrects the run 03 explanation
- **Pre-creation was fast:** the 2000 namespaces took ~18 s, about 9 ms each.
- **The loop then ran at QPS:** 200 iterations every ~2.6 s, i.e. 77 iterations/s × 4 objects ≈ 300 objects/s.
- **Correction to run 03:** in kube-burner v2.8.6, `replicaHandler` waits for the QPS limiter **inside the loop** before starting each object's goroutine, so the object creates are not entirely in the background. Each iteration therefore cost one namespace create plus 4 rate-limiter tokens. The namespace create was slower when it competed with object creates, about 25–30 ms per iteration. Removing the namespace create from the loop made it fully QPS-bound, which is what this test needed.

### The create burst found a limit in the API servers, not in etcd
From 15:11:30 to 15:12:45:
- **API servers:**
  - 150–350 mutating requests in flight on each of the three servers;
  - POST latency averaged 0.4–1.6 s in the first window, then 4–5.4 s;
  - CPU at 5.2–5.6 cores per server.
- **Nodes:** control-plane node CPU reached 92% (cp-01), 81% (cp-02) and 87% (cp-03).
- **kube-burner bypasses APF:** it uses the RKE2 admin account (`system:masters`), which falls in APF's `exempt` priority level. Its requests are never queued or rejected, so they all ran at once.
- **etcd was fine:** ~430 puts/s, fsync p99 ≤ 32 ms, apply lag ≤ 2. Its one failed proposal and 563 slow applies were on cp-03 at 15:12:12.

**Only Services failed** (namespaces 411–~530, created around 15:11:31). Their POSTs hit the API server's default **34 s timeout** for create requests. ConfigMaps, Secrets and Deployments in the same namespaces succeeded. One retry found that the original create had succeeded after all ("already exists"). The API servers recorded only 8 of the timeouts as `POST 504`, all on cp-03, so I can't match each failure to a server.

**Why Services in particular is not proven.** ClusterIP allocation is cheap here: v1.36 creates an `IPAddress` object through a loopback client that is not rate-limited, and there were only ≤37 `POST 409` collisions. The likely cause is that a Service create is the heaviest of the four objects:
- it allocates an `IPAddress`;
- its watch events go to ~1000 Cilium agents;
- it makes kube-controller-manager create EndpointSlices.

All of that landed at the moment of peak CPU. The API server logs would confirm it: they record a `Trace[...]` with step timings for every request slower than 500 ms.

### The ~8 minutes until Ready comes from kube-controller-manager, not from creation
Job start to "Verifying created objects" took 8m00s, 8m00s, 7m59s and 8m19s in runs 01–04, whether objects were created over 100 s or 27 s.

**Pods were not the bottleneck:**
- pod Ready p99 was 4 s;
- the API servers were nearly idle during the wait (1–2 cores, latency < 10 ms);
- etcd was idle.

**But kube-burner waits for each Deployment's `readyReplicas`,** and it saw namespaces complete at only ~24 per minute until 15:17. About 1,900 then completed in two minutes.

**cp-01 shows controller backlog:** cp-01 hosts kube-controller-manager, which uses its local API server. Over that same window cp-01 served a steady ~60 PUT/s and ~40 POST/s with **~5.5 `PUT 409` conflicts/s**. All of it stopped at 15:17:30, exactly when the bulk completion started.

**The default limit explains the numbers:**
- In v1.36, kube-controller-manager defaults to `--kube-api-qps=20 --kube-api-burst=30`, and each controller gets its own client with that limit.
- 2000 Deployments in ~8 minutes is ~4/s, i.e. ~5 API calls per Deployment at 20 QPS: create the ReplicaSet, then several status updates, some of which retry on conflict.
- The deployment controller's client rate limit is therefore the most likely bottleneck.

This is inferred from the timing and the default settings, and not yet confirmed from kube-controller-manager's own metrics or logs.

### Other phases
- **Read** (2m50s) and **patch** (12m28s) were unchanged.
- **Deletes** took 12 / 15 / 30 s. The delete burst was much milder than in runs 02 and 03: nothing was queued and the worst mean DELETE latency was 0.6 s. cp-03 again had the highest PATCH and DELETE latency.
- **APF rejections** rose to 5.2k. They are still only `kube-system-service-accounts` WATCHes, and they cluster at the start of the delete phase (15:36–15:37).
- **Namespace cleanup** took 13 minutes, with ~12.1k `POST 403`, as in previous runs.
- **etcd** slow applies were again concentrated on cp-03 (1,581 of 2,159). The database file grew from 110 to 500 MiB, so defragment again before the next run.

## Recommendations
1. **Confirm where Service creates spend their time.** On each control-plane node, search the API server log for slow-request traces between 15:11:30 and 15:12:30:
   ```bash
   kubectl -n kube-system logs kube-apiserver-bench-cp-0N --since-time=2026-10-26T15:11:00Z \
     | grep -A15 'Trace\[.*"Create".*url:"/api/v1/namespaces/api-intensive-[0-9]*/services"' | head -100
   ```
   If these logs have already rotated, rerun with `PRE_CREATE_NAMESPACES=true` and collect them right after creation.
2. **Confirm the kube-controller-manager throttling:**
   ```bash
   kubectl -n kube-system logs kube-controller-manager-bench-cp-01 --since-time=2026-10-26T15:11:00Z \
     | grep -c 'client-side throttling'
   ```
   If confirmed, raise its client limits in the RKE2 server config on all control-plane nodes, for example `kube-controller-manager-arg: ["kube-api-qps=100", "kube-api-burst=200"]`. Then repeat this run. "Job start → all Deployments Ready" should drop well below 8 minutes. This changes the system under test, so record it with the results.
3. **For a sustainable create rate,** try QPS 150–200 with pre-creation. This run shows that 300 objects/s, with every request exempt from APF, saturates three 8-vCPU control-plane nodes. For a test closer to real clients, run kube-burner with a non-admin identity so that APF applies.
4. **Keep defragmenting etcd between runs.**
