# Split control plane, run 08 — api-intensive, 2000 iterations, QPS 150 / burst 200

Results: `results-api-intensive-20261106T101921Z-TK7My3`. The settings and topology are the same as [run 07](./run_07_analysis.md):
- `ITERATIONS=2000 QPS=150 BURST=200 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`;
- 3 control-plane nodes (16 vCPU / 16 GiB) and 3 dedicated etcd nodes (8 vCPU / 16 GiB);
- 1,000 workers;
- kube-apiserver connects directly to the three etcd members.

**New since run 07** (run 07 recommendations 2 and 3):
- **traefik has its own APF FlowSchema and priority level.** FlowSchema `traefik`, precedence 860, `ByUser`, for `kube-system:rke2-traefik`. Priority level `traefik`: 20 shares, 64 queues, hand of 8, queue length 500.
- **`rebalance.sh` also restarts `rke2-traefik`.** A `rke2-traefik` HelmChartConfig sets `maxUnavailable: 10%`.

Preparation:

| Time (UTC) | Step |
|---|---|
| 09:49 | traefik FlowSchema and priority level applied |
| 10:00 | `rke2-traefik` HelmChartConfig applied |
| 10:02 | Cilium restarted (rebalance) |
| 10:04–10:06 | traefik restarted (rebalance) |
| before 10:19 | defrag |
| 10:19:21 | run start; kube-burner triggered the job at 10:19:43 |

The run started about **15 minutes** after the rebalance. The recommended 1 h wait for the rebalance Events to expire was skipped.

Cluster state at start:
- **Stored objects:** 45.9k (10.6k in run 07), mostly rebalance Events that had not expired yet.
- **etcd DB:** 126 MiB, all in use. It grew to 677 MiB during the run.
- **Goroutines:** **39.6k / 39.8k / 40.7k** (cp-01 / cp-02 / cp-03), within 3 % (run 07: 55.4k / 41.2k / 23.2k).
- **API server RSS:** 7.5 / 7.1 / 6.6 GiB.
- **Leaders:** etcd-01 led throughout, with no leader changes. The KCM leader was cp-01.

## Verdict

**This is the cleanest run of the series.**
- **0 kube-burner errors.**
- **0 API server 429s and no APF rejections.** traefik's own FlowSchema and the traefik restart in `rebalance.sh` removed run 07's 997 Service WATCH 429s.
  - No API server force-closed a Service watcher during the run.
  - The `traefik` priority level never queued a request.
- **The load was balanced.**
  - Goroutines were within 3 % at start.
  - All three CPs created Services: 652 / 559 / 789.
  - Peak node CPU was 54 / 57 / 52 % during creation (run 07: 73 / 62 / 44 %).
- **Pod Ready max 7 s** (16 s in run 07), p99 5 s, avg 2.98 s.

**One problem remains: short TCP stalls between the API servers and etcd.**
- Two etcd requests from **cp-02** failed with `read: connection timed out`:
  - 10:21:14, to etcd-02;
  - 10:30:27, to etcd-01.
- Each failure produced 1 API server 500.
- cp-01 also logged etcd read errors that were retried successfully.
- In run 07 every stall was on cp-01. In this run they hit cp-02 and cp-01, and three different members. That points to the network or the Harvester hosts rather than one VM (finding 2).

**Skipping the 1 h wait made cleanup slightly slower.**
- There were 45.9k stored objects at start, against 10.6k in run 07.
- Patch took 3m06s (2m58s in run 07).
- Removes took 21 / 26 / 34 s (18 / 21 / 30 s in run 07).

## Comparison

| | split run 06 | split run 07 | **split run 08** |
|---|---|---|---|
| API server → etcd | RKE2 etcd proxy | direct (3 endpoints) | direct (3 endpoints) |
| APF for traefik | stock (`workload-high`) | stock (`workload-high`) | **own FlowSchema / priority level** |
| Before the run | defrag, then rebalance | restarts, rebalance (no traefik), wait 1 h, defrag | **rebalance incl. traefik, wait 15 min, defrag** |
| Stored objects / etcd DB at start | 40.9k / 947 MiB | 10.6k / 128 MiB | 45.9k / 126 MiB |
| Goroutines at start | 38.4k / 38.9k / 41.0k | 55.4k / 41.2k / 23.2k | **39.6k / 39.8k / 40.7k** |
| kube-burner errors | 33 create + 90 patch | 1 create (retried) | **0** |
| API server 5xx (creation / total) | 111 / 112 | 1 / 2 | 1 / 2 |
| API server 429s | 0 | 997 (cp-01, Service WATCH) | **0** |
| Service watchers force-closed during the run | – | 15,892 / 1,047 / 0 (since the restarts) | **0** |
| etcd failovers / broken etcd connections | 6 | 0 / 2 (cp-01) | 0 / 2 (**cp-02**) |
| Iteration 1,800 / waiting for actions | 71 s / 87 s | 72 s / 81 s | 70 s / 93 s |
| Job duration | 1m55s | 1m55s | 1m55s |
| Service creates per server | 706 / 884 / 419 | 556 / 0 / 1,445 | **652 / 559 / 789** |
| Mean Service POST, creation | 8.6 / 7.7 / 4.4 s | 8.4 / – / 0.09 s | 5.4 / 9.7 / 5.7 s |
| Mean ClusterIP allocation, creation | 61 / 68 / 59 ms | 99 / – / 19 ms | 65 / 86 / 76 ms |
| Allocator busy, peak window | 74 / 74 / 8 % | 74 / 0 / 39 % | 41 / 65 / 56 % |
| API server process CPU, peak window | 8.1 / 7.3 / 7.3 cores | 8.8 / 7.1 / 4.6 cores | 7.6 / 6.3 / 6.8 cores |
| API server → etcd create latency, creation | 47 / 71 / 46 ms | 69 / 45 / 14 ms | 42 / 65 / 56 ms |
| Peak CP node CPU (creation) | 71 / 63 / 66 % | 73 / 62 / 44 % (92 % cp-01 at 17:35) | **54 / 57 / 52 %** (64 / 64 / 58 % in patch) |
| Peak etcd node CPU | ≤ 16 % | ≤ 21 % | ≤ 19 % |
| Pod Ready p99 / max / avg | 5 / 6 / 3.1 s | 6 / 16 / 3.1 s | **5 / 7 / 3.0 s** |
| PodScheduled p99 / Initialized p99 | 2.1 s / 2 s | 2.9 s / 2 s | 1.8 s / 2 s |
| APF `system` queued (max) | 0 | 0 | 0 |
| Read / patch | 5m39s / 2m58s | 5m40s / 2m58s | 5m39s / 3m06s |
| remove-deployments / services / configs | 19 / 21 / 31 s | 18 / 21 / 30 s | 21 / 26 / 34 s |
| API server peak RSS | 8.1 / 7.9 / 8.3 GiB | 8.6 / 6.8 / 5.2 GiB | 7.5 / 7.2 / 7.0 GiB |
| Namespace cleanup | 13m52s | 13m29s | 13m19s |

Triples are cp-01 / cp-02 / cp-03. The windows are aligned on the last server's sample:
- **Creation:** 10:19:40 → 10:21:33.
- **Peak:** 10:20:22 → 10:21:33 (10:20:31 for cp-03).

## Findings

### 1. traefik no longer causes 429s

| | run 07 | run 08 |
|---|---|---|
| Service watchers force-closed (`apiserver_terminated_watchers_total{resource="services"}`) | 15,892 on cp-01 | none during the run |
| APF `queue-full` rejections | 997 on cp-01 at 17:35 | 0 on any server |
| `apiserver_request_terminations_total` during the run | 997 | 0 |
| `traefik` priority level | – | in-queue 0 at every sample, executing ≤ 2 |

Two things contributed:
- **The balance.**
  - Restarting traefik spread its 1,000 pods' watches evenly, so no server was overloaded enough for its Service watchers to fall behind.
  - At remove-configs (10:32–10:33), node CPU peaked at 48–50 % on all three CPs. In run 07, cp-01 alone reached 92 %.
- **The FlowSchema.** If watchers are force-closed again, the 1,000 traefik re-watches now queue in their own priority level, which has 64 queues of up to 500. Before, they shared one flow in `workload-high`. This was not exercised in this run.

Other APF activity was negligible:
- `workload-high` held at most 3 requests in queue (cp-01).
- `system` executed at most 9 / 13 / 12 requests, with nothing queued.
- `cilium` in-queue was 0.

The cumulative rejection counters still show values from before the FlowSchema:
- `kube-system-service-accounts`: 18,087 on cp-01 and 12,630 on cp-02;
- `cilium`: 50 on cp-01 and 2,918 on cp-02.

None of these counters increased during the run.

### 2. The etcd TCP stalls continue, and they are not specific to one CP

| Time | API server | etcd member | Request | Effect |
|---|---|---|---|---|
| 10:21:14 | cp-02 | etcd-02 | Txn, `read: connection timed out` | 1 POST 500, 1 `etcd_request_errors_total{operation="create"}` |
| 10:21:16 | cp-01 | etcd-03 | Range, `error reading from server` | retried, no error |
| 10:25:37 | cp-01 | etcd-01 | `createTransport ... error reading server preface` | reconnect |
| 10:30:27 | cp-02 | etcd-01 | Txn, `read: connection timed out` (during patch) | 1 POST 500 |
| 10:42:37 | cp-03 | etcd-03 | handshake failed (context) | reconnect |

As in run 07:
- **`read: connection timed out` means about 10 s without a TCP acknowledgment** (gRPC's `TCP_USER_TIMEOUT`).
- Both stalls happened at busy moments: the end of creation, and the patch peak (64 % CPU).
- etcd was idle:
  - CPU ≤ 19 %;
  - WAL fsync 1.3–1.6 ms, backend commit 2.8–3.4 ms;
  - peer RTT 2.5–2.7 ms;
  - 6 / 5 / 18 slow applies during the run, 0 failed proposals.

What is new:
- **The stalls moved from cp-01 to cp-02.** Run 07's stalls were all on cp-01, which was also the overloaded server. Now that the load is even, they show up on cp-02.
- Across both runs, all three etcd members have been on the far end of a stall.
- The cause is therefore not one VM or one etcd member. Most likely it is the Harvester network path (VM bridge or overlay, or host NIC) under load.

kube-burner logged no error for either 500. The failed POSTs were probably requests from controllers or other clients, which retry silently, rather than kube-burner creates. This could not be confirmed: the metric has no resource label.

Other log entries, all harmless:
- At 10:20:31 and 10:20:34, cp-02 and cp-03 logged `Failed to get storage metrics` (Status `DeadlineExceeded`) during the peak.
- At 10:32:05, cp-02 logged "Too large resource version".
- The once-a-minute `createTransport ... operation was canceled` to etcd-01 continues, as in run 07.

### 3. Even load: what it bought

| | run 07 (cp-01 / cp-03) | run 08 (cp-01 / cp-02 / cp-03) |
|---|---|---|
| Node CPU during creation | 73 % / 44 % | 54 / 57 / 52 % |
| Mean Service POST | 8.4 s / 0.09 s | 5.4 / 9.7 / 5.7 s |
| Mean ClusterIP allocation | 99 / 19 ms | 65 / 86 / 76 ms |
| Pod Ready max | 16 s | 7 s |

- Even load removed the hotspot and the pod-latency tail.
- **Mean Service POST is still 5–10 s** on every server. Service creation is serialised on the ClusterIP allocator, which was 41–65 % busy in the peak window.
- The last 200 iterations took 23 s (about 9 s in run 07), so "waiting for actions" came at 93 s. The job duration was still 1m55s, so throughput was unaffected.
- Peak etcd create latency was 42 / 65 / 56 ms, which is mostly client-side, as in run 07.

### 4. The rebalance was too close to the run

- 45.9k stored objects at start (10.6k in run 07, 40.9k in run 06). These are Events from the Cilium and traefik restarts about 15 min earlier. Events have a 1 h TTL.
- The defrag reset the DB file to 126 MiB, but it cannot remove live keys.
- Compared with run 07:
  - patch took 8 s longer;
  - each remove step took 3–5 s longer.
- The effect is small. Run 06, with 40.9k objects, had the same pattern.

### 5. Everything else

- **Throughput:** client-bound. Iteration 1,800 came at 70 s, and read took 5m39s.
- **KCM (cp-01):**
  - 6,075 PUT 409s and no new 500s;
  - queue peaks: GC `attempt_to_delete` 3,442, deployment 1,991, namespace 1,979, replicaset 1,188, endpoint_slice 692.
- **etcd:**
  - no leader changes;
  - DB 126 → 677 MiB;
  - Range rate during creation 444 / 447 / 399 per second;
  - pending proposals max 8.
- **Cleanup:** namespace cleanup took 13m19s, the fastest of the series. During it, cp-01 (the KCM leader) ran at about 11 % node CPU, and the others at 7 %.
- **API server RSS** peaked at 7.5 / 7.2 / 7.0 GiB, evenly.

## Recommendations

1. **Keep the current setup:** direct etcd, the traefik FlowSchema, and traefik in `rebalance.sh`.
2. **Wait 1 h between the rebalance and the run** (or delete the Events with `kubectl delete events -A --all`), then defrag. This brings stored objects back to about 10k and recovers the few seconds lost in patch and removes.
3. **Investigate the TCP stalls, now as a network issue.** They have hit every etcd member and two of the three CPs.
   - During the next run, take `nstat -az TcpExtTCPTimeouts TcpRetransSegs` deltas on all six nodes.
   - Run a 1 s ping loop from each CP to each etcd member, and record the maximum RTT.
   - Map the VMs to Harvester hosts (`kubectl get vmi -A -o wide` on Harvester). If the CP and etcd VMs share hosts with heavily loaded workers, try anti-affinity or a dedicated host for the control plane.
4. **Next steps for capacity, unchanged from run 06:**
   - Enlarge `bench-net-01` to 4 vCPU / 8 GiB.
   - Then raise QPS to 200–250, with KCM `kube-api-qps` 200 / `kube-api-burst` 400. The CPs peaked at 57 % (64 % in patch), so there is headroom.
   - Downsize etcd to 4 vCPU / 8 GiB: ≤ 19 % CPU.
   - Configure off-cluster etcd snapshots.
