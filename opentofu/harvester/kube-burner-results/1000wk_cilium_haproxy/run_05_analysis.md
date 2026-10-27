# haproxy + keepalived run 05: repeat of run 04

Run `results-api-intensive-20261027T100021Z` used the same cluster, and etcd was defragmented first (database at 111 MiB). Settings are identical to run 04, from `parameters.env`: `ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true ETCD_METRICS=required`. Nothing else in the cluster was changed, so this run tests whether run 04 is reproducible.

## Verdict

**Run 04 reproduced, except that nothing failed this time.**
- **The create burst stressed the API servers as much as in run 04:** the control-plane nodes peaked at 85–91% CPU, up to 359 mutating requests were in flight, and POST latency averaged up to 4.9 s (5.4 s in run 04).
- **This time there were no errors:** no kube-burner errors, no 5xx and no 504s. The slowest creates still finished ~30 s after the loop ended, just under the API server's 34 s create timeout. The 119 Service timeouts in run 04 were therefore marginal: 300 objects/s with every request exempt from APF sits right at the limit of these three control-plane nodes. It will fail in some runs and not in others.
- **The time until all Deployments were Ready was unchanged:** 8m13s, with the same kube-controller-manager signature as before.

## Comparison

| | haproxy 03 | haproxy 04 | haproxy 05 |
|---|---|---|---|
| QPS / BURST / pre-create | 300 / 400 / no | 300 / 400 / yes | 300 / 400 / yes |
| kube-burner errors / API 5xx | 0 / 0 | 119 Service timeouts (retried) / 8 | **0 / 0** |
| Namespace pre-creation | – | ~18 s | ~13 s |
| Object creation (8000 objects) | ~90 s | ~27 s (~300/s) | ~27 s (~300/s) |
| Last iteration → all creates returned | – | 33 s | 32 s |
| Create phase: mean POST latency, worst 30 s window | 74 ms | 5.4 s | 4.9 s (cp-03) |
| Create phase: peak mutating requests in flight | – | 352 | 359 (cp-01) |
| Create phase: control-plane node CPU peak | 84% | 92% | 91% (cp-01) |
| Job start → all Deployments Ready | 7m59s | 8m19s | 8m13s |
| Pod Ready p99 / max | 3 / 5 s | 4 / 6 s | 3 / 4 s |
| Read / patch | 2m48s / 12m28s | 2m50s / 12m28s | 2m49s / 12m28s |
| remove-deployments / services / configs | 11 / 11 / 21 s | 12 / 15 / 30 s | 11 / 13 / 23 s |
| Delete burst: queued / worst mean DELETE | 415 / 0.8 s | 0 / 0.6 s | 0 / 0.8 s (cp-03) |
| APF rejections (`kube-system-service-accounts` WATCH) | 3,595 | 5,164 | 3,141 |
| etcd slow applies / failed proposals | 2,669 / 0 | 2,159 / 1 | 1,669 / 0 |
| etcd fsync / commit p99 (whole run) | 8 / 16 ms | 8 / 16 ms | 8 / 16 ms |
| etcd database file (start → end) | 110 → 512 MiB | 110 → 500 MiB | 111 → 497 MiB (178 MiB in use) |
| Namespace cleanup | 12m59s | 12m59s | 12m57s |

## Findings

### The create burst: same load as run 04, without the timeouts
The namespaces were pre-created from 10:00:25 to ~10:00:38. The loop then ran at QPS, 200 iterations every ~2.6 s, until ~10:01:05. kube-burner logged "Waiting for actions" only at 10:01:34, after the last create had returned.

From 10:00:25 to 10:01:30:
- **API servers:**
  - 215–359 mutating requests in flight on each server;
  - POST latency averaged 0.3–0.5 s in the first window, then 2.0 s (cp-01), 3.0 s (cp-02) and 4.9 s (cp-03);
  - in the next window, cp-03 POSTs still averaged 3.0 s while the last slow creates completed;
  - 4.6–5.9 cores per server.
- **Nodes:** control-plane node CPU reached 91% (cp-01), 85% (cp-02) and 89% (cp-03).
- **etcd was fine:** ~450 puts/s, fsync p99 ≤ 32 ms, commit p99 ≤ 32 ms and at most 24 pending proposals. There were no failed proposals. 252 slow applies occurred during the burst, 136 + 116 of them on cp-03.
- **APF:** nothing was queued, because kube-burner's admin identity is exempt from APF.

cp-03 again had the worst latency and the most slow applies. Run 04's 504s were also all on cp-03. cp-03 also had the most etcd slow applies in runs 03 and 04, so it is consistently the slowest member. Check its disk and its Harvester host.

### The ~8 minutes until Ready: same kube-controller-manager signature
Job start to "Verifying created objects" took 8m13s.

**Namespaces completed slowly, then all at once:** about 24 per minute from 10:01 to 10:05, then ~1,870 between 10:06 and 10:08.

**cp-01 shows the same controller backlog as in run 04:** throughout the wait, cp-01, which hosts kube-controller-manager, served ~40 POST/s and ~60 PUT/s with ~5.6 `PUT 409` conflicts/s. The conflicts stopped in the 10:07 window, exactly when the bulk completion happened. The API servers and etcd were otherwise nearly idle: 1–2 cores, < 10 ms latency, ~210 puts/s.

Nothing about kube-controller-manager was changed, so this is expected. Run 04's recommendation 2 is still open.

### Other phases
- **Read** (2m49s) and **patch** (12m28s) were identical to runs 03 and 04.
- **Deletes** took 11 / 13 / 23 s. During the delete burst (10:25:05–10:26:40):
  - the control-plane nodes peaked at 82–84% CPU;
  - DELETEs averaged up to 0.84 s (cp-03) and 0.77 s (cp-02);
  - nothing was queued.
- **APF rejections** fell to 3.1k. They are still only `kube-system-service-accounts` WATCHes, and all of them happened in the first minute of the delete phase (10:25:05–10:26:09).
- **Namespace cleanup** took 13 minutes, with ~13.8k `POST 403`, as in previous runs.
- **etcd:**
  - there were no leader changes, and cp-01 stayed the leader;
  - slow applies were again concentrated on cp-03 (828 of 1,669);
  - the database file grew from 111 to 497 MiB, of which only 178 MiB is in use, so defragment again before the next run.

## Recommendations
1. **Treat 300 objects/s as the edge, not as a pass.** Runs 04 and 05 had the same load. One lost 119 Service creates to the 34 s timeout and the other did not. For a create rate that passes reliably, use QPS 150–200, or tune and confirm the limit with several repeats.
2. **Confirm and fix the kube-controller-manager throttling.** This is still the main open item, as in run 04's recommendations 1–2. Check `client-side throttling` in the kube-controller-manager log on cp-01 for 10:01–10:07. Then raise `kube-api-qps` / `kube-api-burst` and repeat this run. "Job start → all Deployments Ready" should drop well below 8 minutes.
3. **Look at cp-03.** It had the highest POST and DELETE latency and the most etcd slow applies in runs 03–05. Compare its disk latency and Harvester host placement with cp-01 and cp-02.
4. **Keep defragmenting etcd between runs.**
