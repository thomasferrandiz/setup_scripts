# haproxy + keepalived run 03: api-intensive, 2000 iterations at QPS 300

Run `results-api-intensive-20261026T123744Z` used the same cluster as runs 01 and 02, with etcd defragmented first. Settings, from `parameters.env`: `ITERATIONS=2000 QPS=300 BURST=400 ETCD_METRICS=required`, with defaults for the rest. The only change from run 02 is QPS, raised from 200 to 300.

## Verdict

The run was **clean for the third time**: kube-burner logged 0 errors, the API servers returned no 5xx, etcd had no failed proposals and no leader changes, and all 1003 nodes were Ready at the end. Pod latency stayed at the run 02 level.

Raising QPS only sped up the phases that QPS actually limits: reads and deletes. **Creation did not get faster, because kube-burner's create loop doesn't depend on QPS** (see below).

## Comparison

| | haproxy 01 | haproxy 02 | haproxy 03 |
|---|---|---|---|
| QPS / BURST | 200 / 200 | 200 / 400 | **300** / 400 |
| kube-burner errors / API 5xx | 0 / 0 | 0 / 0 | 0 / 0 |
| Create loop (2000 iterations) | ~92 s | ~100 s | ~90 s |
| Pod Ready p99 (create) | 23 s (cold images) | 3 s | 3 s |
| Read (5 iterations) | 4m10s | 4m10s | **2m48s** |
| Patch | 12m39s | 12m37s | 12m28s |
| remove-deployments / services / configs | 14 / 14 / 30 s | 13 / 16 / 29 s | **11 / 11 / 21 s** |
| Delete burst: in-flight mutating / queued (max, one server) | ~10 / 0 | 254 / 485 | 286 / 415 (cp-03) |
| Delete burst: mean DELETE latency (worst 30 s window) | 1.1 s | 0.8 s | 0.8 s |
| APF rejections (all `kube-system-service-accounts` WATCH) | 8,877 | 3,619 | 3,595 |
| etcd slow applies / failed proposals | 1,482 / 0 | 2,185 / 0 | 2,669 / 0 |
| etcd max apply lag | 3 | 2 | **307** (cp-03, one sample) |
| etcd database file (start → end) | 154 → 513 MiB | 111 → 494 MiB | 110 → 512 MiB |
| Namespace cleanup | 12m48s | 12m49s | 12m59s |

## Findings

### Creation speed is set by namespace round-trips, not QPS
This comes from kube-burner v2.8.6's `runCreateJobDefault` and `replicaHandler` (`pkg/burner/create.go`). With `namespacedIterations: true`, each iteration first calls `createNamespace`, which **waits for the response** before going on. The loop then waits for 4 QPS-limiter tokens, one per object, and the creates themselves run in the background. So each iteration costs one namespace create plus 4/QPS. (Correction from run 04: the limiter wait was originally described as being in the background.)

- **The numbers fit:** 22 iterations/s is about 45 ms per iteration, which is a namespace POST through haproxy (20–50 ms on the server, plus the network hop). That is why QPS 200 or 300 and BURST 200 or 400 all gave ~9–10 s per 200 iterations.
- **Not an API-server limit:** during create, request latency stayed low with nothing queued. All three control-plane nodes ran at 72–84% CPU, about the same as in runs 01 and 02.

To push creation harder, the workload has to change, not QPS:
- `preCreateNamespaces: true` creates all namespaces before the loop. It still creates them one at a time, but on an idle API server that took only ~18 s for 2000 (run 04). The object-creation loop then waits only on the rate limiter, which separates "namespaces/s" from "objects/s at a given QPS".
- Alternatively, set `namespacedIterations: false`, or create more objects per iteration (`replicas`), so the namespace round-trip is shared across more objects.

### QPS does limit reads and deletes
- **Read:** 2m48s against 4m10s. The ratio is 0.67, exactly 200/300, so this phase is limited by kube-burner's QPS. LIST latency on the server kube-burner used stayed at 67–83 ms.
- **Deletes:** 11 / 11 / 21 s against 13–14 / 14–16 / 29–30 s.
- **Patch** didn't change (12m28s). It is dominated by Deployment rollouts, not request rate.

### The delete burst always lands hardest on bench-cp-03
In this run, kube-burner was connected to cp-02 (116k LISTs there, 99 on cp-03). Even so, cp-03 again took the worst of the delete burst:
- 286 in-flight mutating requests and 415 queued;
- DELETE latency of 570–770 ms;
- 1,638 of the APF rejections;
- its etcd member fell **307 proposals behind** for one sample at 13:03:03 and logged 1,534 slow applies. It had caught up by the next sample, and no proposals failed.

This matches runs 01 and 02. cp-03 holds ~30% more watches (46k goroutines against 35–36k), so it serves more kubelets and Cilium agents and does more fan-out work when thousands of pods, Services and EndpointSlices disappear at once. With `leastconn`, connections are balanced, but how much work each client generates is not.

### Unchanged
- **Namespace cleanup** took about 13 minutes and went almost entirely through cp-01 (161k DELETEs, ~550 req/s). cp-01 hosts the kube-controller-manager leader.
- **`POST 403`:** about 12.4k, again during cleanup.
- **etcd disk** stayed healthy: fsync p99 8 ms and commit p99 16 ms over the run, worst window 32 / 64 ms. The leader stayed on cp-01 (≤ 0.76 cores). The database file grew from 110 to 512 MiB, so defragment again before the next run.
- **The API servers still haven't been restarted,** and their memory at the start is similar to run 02 (5.6 / 4.4 / 5.4 GiB).

## Recommendations
1. **The control plane handles this workload comfortably at QPS 300.** To find the real object-creation limit, enable `preCreateNamespaces: true` on the `api-intensive` job, then raise QPS. Raising `replicas` per iteration also works.
2. **Watch cp-03 during the delete burst.** This was the first run where an etcd member built an apply backlog (307). If QPS or BURST goes higher, that is where trouble will start. Two options:
   - give the delete jobs their own lower QPS;
   - rebalance watches, for example with `--goaway-chance` on the API servers, or by restarting the API server on cp-03 so that its clients reconnect elsewhere.
3. **Keep defragmenting etcd between runs,** and record which server kube-burner landed on: the one with the most LISTs.
