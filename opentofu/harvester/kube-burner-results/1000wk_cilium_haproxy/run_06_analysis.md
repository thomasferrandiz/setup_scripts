# haproxy + keepalived run 06: second repeat of run 04

Run `results-api-intensive-20261027T111317Z` used the same cluster, and etcd was defragmented first (database at 106 MiB). Settings are identical to runs 04 and 05: `ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true ETCD_METRICS=required`. kube-controller-manager was not changed: the readiness signature below is identical.

## Verdict

**Run 06 is almost the same as run 05.** kube-burner logged no errors, and every phase took the same time to within a few seconds.
- **The create burst caused the highest latency so far, but nothing timed out:**
  - control-plane nodes peaked at 83–89% CPU;
  - up to 359 mutating requests were in flight;
  - the last creates completed in a window where cp-03 POSTs averaged 6.3 s, versus 5.4 s in run 04, which failed.

  Whether any create crosses the 34 s timeout therefore varies from run to run: 1 run in 3 at this load had failures.
- **The time until all Deployments were Ready was again ~8 minutes (8m17s)**, still limited by kube-controller-manager.
- **New in this run:** 10 `GET 500` responses on cp-03 during the delete burst. etcd also recorded more slow applies than in any earlier run (3,818, of which 2,415 were on cp-03). It still had no failed proposals, and fsync p99 stayed at 8 ms over the whole run.

## Comparison

| | haproxy 04 | haproxy 05 | haproxy 06 |
|---|---|---|---|
| kube-burner errors / API 5xx | 119 Service timeouts (retried) / 8 × `POST 504` | 0 / 0 | 0 / **10 × `GET 500`** (cp-03, delete phase) |
| Namespace pre-creation | ~18 s | ~13 s | ~16 s |
| Object creation (8000 objects) | ~27 s | ~27 s | ~27 s |
| Last iteration → all creates returned | 33 s | 32 s | ~30 s |
| Create phase: mean POST latency, worst 30 s window | 5.4 s | 4.9 s | **6.3 s** (cp-03) |
| Create phase: peak mutating requests in flight | 352 | 359 | 359 (cp-01) |
| Create phase: control-plane node CPU peak | 92% | 91% | 89% (cp-01) |
| Job start → all Deployments Ready | 8m19s | 8m13s | 8m17s |
| Pod Ready p99 / max | 4 / 6 s | 3 / 4 s | 4 / 5 s |
| Read / patch | 2m50s / 12m28s | 2m49s / 12m28s | 2m48s / 12m28s |
| remove-deployments / services / configs | 12 / 15 / 30 s | 11 / 13 / 23 s | 12 / 13 / 30 s |
| Delete burst: queued / worst mean DELETE | 0 / 0.6 s | 0 / 0.8 s | 0 / 0.7 s (cp-02) |
| APF rejections (`kube-system-service-accounts` WATCH) | 5,164 | 3,141 | 3,902 |
| etcd slow applies (cp-01 / cp-02 / cp-03) / failed proposals | 221 / 357 / 1,581 / 1 | 479 / 362 / 828 / 0 | **675 / 728 / 2,415** / 0 |
| etcd fsync / commit p99 (whole run) | 8 / 16 ms | 8 / 16 ms | 8 / 16 ms (cp-03: 32 ms) |
| etcd database file (start → end) | 110 → 500 MiB | 111 → 497 MiB | 106 → 489 MiB (172 MiB in use) |
| Namespace cleanup | 12m59s | 12m57s | 12m46s |

## Findings

### The create burst
The namespaces were pre-created from 11:13:21 to ~11:13:37. The loop then ran at QPS, 200 iterations every ~2.6 s, until ~11:14:05. "Waiting for actions" was logged at 11:14:34, after the last create had returned.

**API servers:**

| Window ending | cp-01 | cp-02 | cp-03 |
|---|---|---|---|
| 11:13:53 | 359 mutating in flight, POST 0.26 s | 208, 0.23 s | 217, 0.24 s |
| 11:14:25 | POST 2.0 s | 3.5 s | 3.3 s, 263 in flight |
| 11:14:57 | – | 3.4 s | **6.3 s** |

The API server processes used 5.5–5.7 cores each.

**Nodes:** control-plane node CPU peaked at 89% (cp-01), 83% (cp-02) and 88% (cp-03). cp-03 stayed at 84% for one window longer than the others.

**etcd:**
- ~400–430 puts/s, fsync p99 ≤ 32 ms and at most 12 pending proposals;
- 473 slow applies during the burst, 420 of them on cp-03;
- no failed proposals.

As in runs 04 and 05, cp-03 was the last server to work through its backlog of creates. Run 04's 504s were also on cp-03.

### The ~8 minutes until Ready: unchanged
**Namespaces completed slowly, then all at once:** 21–25 per minute from 11:14 to 11:18, then ~1,875 between 11:19 and 11:21.

**cp-01 showed the same kube-controller-manager signature:** ~40 POST/s, ~60 PUT/s and ~5.6 `PUT 409`/s. The conflicts stopped in the 11:20 window, when the bulk completion happened. It is the third identical result, so this bottleneck is fully reproducible and independent of how fast the objects were created.

### Delete phase and the 10 `GET 500`
**Load:** during the delete burst, 11:38:00–11:40:05:
- control-plane nodes peaked at 84% CPU;
- DELETEs averaged up to 0.70 s (cp-02);
- APF queued nothing.

**cp-03 was the most loaded:**
- POST 0.81 s and PATCH 0.21 s in the first window;
- PUT 0.39 s in the 11:39:35 window;
- etcd request latency up to 114 ms;
- 965 slow applies in that window, with commit p99 at 64 ms.

**The 10 `GET 500`** occurred in that same window on cp-03. The metrics don't show the resource or the client, but the timing matches cp-03's local etcd falling behind. Only the API server log for 11:39:00–11:39:40 can identify them. kube-burner was not affected.

**Other observations:**
- **APF rejections** were 3.9k. They are still only `kube-system-service-accounts` WATCHes, all at the start of the delete phase (11:38:00–11:39:35).
- **Namespace cleanup** took 12m46s, with ~11.3k `POST 403`, as in previous runs.

### etcd
- **Slow applies were the highest so far:** 3,818, versus 1,669 in run 05. 64% were on cp-03, mostly in the create burst and the delete burst.
- **Otherwise etcd was healthy:** no failed proposals, no leader changes, and cp-01 stayed the leader.
- **Disk latency stayed low:** fsync p99 was 8 ms on every member. Commit p99 was 16 ms on cp-01 and cp-02, but 32 ms on cp-03.
- **The database file grew from 106 to 489 MiB**, of which 172 MiB is in use. Defragment before the next run.

## Recommendations
1. **Stop repeating this configuration.** Three runs give a consistent picture:
   - 300 objects/s through an APF-exempt client runs three 8-vCPU control-plane nodes at ~90% CPU, with create latencies of 5–6 s;
   - whether any create crosses the 34 s timeout varies from run to run;
   - readiness always takes ~8 minutes.

   Further runs need a change to the system or to the load.
2. **Fix kube-controller-manager next.** Confirm `client-side throttling` in its log on cp-01. Then set `kube-controller-manager-arg: ["kube-api-qps=100", "kube-api-burst=200"]` on all control-plane nodes and rerun this exact configuration. If throttling was the bottleneck, "Job start → all Deployments Ready" should drop well below 8 minutes.
3. **Investigate cp-03.** In every run it has the worst API latency, the most etcd slow applies and the highest commit latency, and now it also returned `GET 500`s.
   - Compare its disk latency and Harvester host placement with cp-01 and cp-02.
   - Check `kube-apiserver-bench-cp-03` logs around 11:39:00–11:39:40 for the 500s.
4. **For a load that passes reliably,** use QPS 150–200. For realistic flow control, run kube-burner with a non-admin identity so that APF applies.
5. **Keep defragmenting etcd between runs.**
