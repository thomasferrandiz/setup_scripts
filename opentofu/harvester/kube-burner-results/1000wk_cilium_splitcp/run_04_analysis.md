# Split control plane, run 04 — api-intensive, 2000 iterations, QPS 150 / burst 200

Results: `results-api-intensive-20261104T093048Z-MNnfE1`. The settings and topology are the same as [run 03](./run_03_analysis.md): 3 control-plane nodes (API server, KCM and scheduler) and 3 dedicated etcd nodes, all 8 vCPU / 16 GiB, with 1,000 workers. `ITERATIONS=2000 QPS=150 BURST=200 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`. The VMs are on the same Harvester hosts, and the API servers still use `--etcd-servers=https://127.0.0.1:2379`, the RKE2 etcd load balancer.

Cluster state at start:
- **The API servers were balanced for the first time:**

  | | cp-01 | cp-02 | cp-03 |
  |---|---|---|---|
  | Goroutines | 40.4k | 40.3k | 37.3k |
  | API server RSS | 7.8 GiB | 7.9 GiB | 7.0 GiB |

  In run 03: 45.6k / 44.3k / 28.3k.
- **etcd:** 143 MiB (defragmented). etcd-01 was the leader for the whole run, with no leader changes.
- **KCM leader: cp-01** for the whole run.

## Verdict

**Balancing the API servers worked as expected:**
- Service creates were spread over all three servers.
- No Service timed out, and the job was the fastest of the series (1m54s).
- Namespace cleanup dropped to 12m06s.

**The run was not clean, though: 13 kube-burner errors (EOF), all from cp-01 losing its etcd connections twice in 6 seconds.** This is the same RKE2 etcd load balancer failover as in runs 01–03.

Runs 02–04 show that this failover happens in every run under load. Whether it causes client errors is luck. **It is the only remaining source of errors in the split topology.**

## Comparison

| | haproxy run 15 (3 stacked CP) | split run 02 | split run 03 | **split run 04** |
|---|---|---|---|---|
| Goroutines at start | — | 46.7k / 49.1k / 21.7k | 45.6k / 44.3k / 28.3k | **40.4k / 40.3k / 37.3k** |
| kube-burner errors | 0 | 18 (17 EOF, 1 timeout) | 0 | **13** (12 EOF, 1 IP allocation EOF) |
| Service create timeouts | 0 | 1 | 0 | **0** |
| API server 5xx (creation / total) | 0 | 22 / 22 | 0 / 12 | **39 / 39** (all cp-01) |
| Active etcd failovers during the run | n/a | 1 (cp-02) | 1 (cp-03, removes) | **2 (cp-01, 09:32:12 and 09:32:18)** |
| Iteration 1,800 / waiting for actions | — | 67 s / 76 s | 69 s / 88 s | 68 s / 91 s |
| Job duration | — | 2m03s | 2m02s | **1m54s** |
| Service creates per server | — | 295 / 507 / 1,201 | 484 / 410 / 1,106 | **244 / 890 / 868** |
| Combined allocation rate, peak window | ~30/s | ~27/s | ~24/s | ~27/s (3.9 / 12.0 / 10.9) |
| Mean ClusterIP allocation, creation | 86 / 157 / 87 ms | 178 / 109 / 19 ms | 134 / 83 / 23 ms | 126 / 77 / 75 ms |
| Mean Service POST, creation | 10–22 s | 13.9 / 9.2 / 0.05 s | 17.5 / 5.5 / 0.12 s | 7.6 / 13.2 / 10.9 s |
| Allocator busy, peak window | — | 74 / 74 / 34 % | 82 / 43 / 33 % | 49 / **89 / 83 %** |
| API server → etcd create latency, creation | 67–74 ms | 86 / 83 / 14 ms | 56 / 38 / 15 ms | 54 / 56 / 41 ms |
| Peak CP node CPU (creation) | 86 / 95 / 82 % | 98 / 95 / 55 % | 91 / 80 / 62 % | **98 / 93 / 92 %** |
| Peak etcd node CPU | (stacked) | ≤ 16 % | ≤ 18 % | ≤ 20 % |
| Pod Ready p99 / max / avg | 5 / 6 / 3.0 s | 5 / 6 / 2.8 s | 4 / 5 / 2.6 s | 4 / 6 / 2.9 s |
| PodScheduled p99 / Initialized p99 | 1.6 s / 1 s | 1.9 s / 2 s | 1.3 s / 1 s | 1.7 s / 1 s |
| Read / patch | 5m39s / 2m58s | 5m40s / 3m12s | 5m40s / 3m07s | 5m40s / 3m08s |
| remove-deployments / services / configs | 18 / 22 / 40 s | 22 / 23 / 41 s | 25 / 24 / 41 s | 20 / 22 / 40 s |
| APF rejections (during creation) | 1,743 (0) | 3,298 (0) | 2,011 (77) | **2,099 (0)** |
| API server peak RSS | 7.6 / 8.1 / 7.8 GiB | 8.5 / 8.8 / 4.8 GiB | 8.4 / 8.6 / 6.8 GiB | 8.7 / 8.6 / 7.7 GiB |
| Namespace cleanup | 11m54s | 14m03s | 13m55s | **12m06s** |

All triples are cp-01 / cp-02 / cp-03. The metrics scraper only got a sample every 40–60 s under load. The "creation" window is therefore 09:31:07 → 09:32:46, and the "peak" window is 09:31:48 → 09:32:46.

## Findings

### 1. Balanced API servers: the load is spread, and there is no idle server left to absorb it

kube-burner sent iterations 200 → 1,800 between 09:31:36 and 09:32:18. That is ~37 Services/s, as in every run of the series.

Creation window (09:31:07 → 09:32:46):

| Server | Service POSTs | Mean POST | Mean allocation | Allocator busy (peak) | etcd create | Process CPU | All POSTs |
|---|---|---|---|---|---|---|---|
| cp-01 (KCM leader) | 244 | 7.6 s | 126 ms | 49 % | 54 ms | 5.9 cores | **17,048** |
| cp-02 | 890 | 13.2 s | 77 ms | **89 %** | 56 ms | 5.6 cores | 12,884 |
| cp-03 | 868 | 10.9 s | 75 ms | **83 %** | 41 ms | 5.8 cores | 9,921 |

- **HAProxy `leastconn` now steers kube-burner away from cp-01.** cp-01 already carries the KCM leader's connections, so it received only 12 % of the Service creates. In run 03 it received 24 % and averaged 17.5 s per POST. The worst server's mean POST went from 17.5 s to 13.2 s. That is the result recommended after run 03, obtained by balancing alone.
- **In runs 02 and 03, cp-03 hid how close the cluster was to its limit.** It was underloaded and allocated at about 20 ms. Now all three servers run at 5.6–5.9 cores, and allocation costs 75–126 ms everywhere. The combined rate stays at about 27 Services/s, against 37/s sent.
- cp-02 and cp-03 had their allocators 83–89 % busy, with a 13–15 s mean POST in the peak window. That is about a quarter of the 60 s timeout. At the same QPS there is margin. **At a higher QPS, or for longer bursts, the cluster will hit timeouts again.** The three API servers are saturated at about 27 Services/s, and node CPU peaked at 98 / 93 / 92 %.
- The job was the fastest of the series (1m54s). Pod Ready p99 was 4 s, the same as run 03.

### 2. The EOF errors: cp-01 failed over twice in 6 seconds

cp-01's `rke2-server` journal:

```
09:31:37  etcd-02:2379@HEALTHY->FAILED           (standby)
09:31:52  etcd-02 RECOVERING->PREFERRED
09:32:12  etcd-03:2379@ACTIVE->FAILED
09:32:12  Closing 137 connections to load balancer server etcd-03:2379
09:32:12  etcd-02:2379@PREFERRED->ACTIVE
09:32:18  etcd-02:2379@ACTIVE->FAILED
09:32:18  Closing 133 connections to load balancer server etcd-02:2379
09:32:18  etcd-01:2379@HEALTHY*->ACTIVE
09:32:51  etcd-03 PREFERRED->FAILED              (standby)
```

- **The first cut (09:32:12)** caused 11 kube-burner EOF errors in the same second: Deployments, Secrets and ConfigMaps in namespaces 1572–1576.
- **The second cut (09:32:18)** caused a ClusterIP allocation failure (`failed to allocate IP ... EOF`, a 422) at 09:32:19. A queued Service create failed with EOF at 09:32:30.
- One of the retried Deployments returned `already exists`: the first attempt had in fact been written.
- **Server side, all on cp-01:** 25 etcd create errors and 14 etcd update errors. That gives 25 POST, 9 PUT and 5 PATCH 500s, 1 POST 422 and 2 ClusterIP allocation errors. The KCM saw 4 of the PUT 500s.
- The other two servers also failed health checks during the peak, but only on standby members: cp-02 on etcd-01 at 09:32:06, and cp-03 on etcd-03 at 09:31:52.

What this run adds:
- **Every CP node failed at least one health check during the 60 s peak.** Over runs 02–04, every run has had active-member failovers. Run 04 had two in a row on the same node, because the PREFERRED member it moved to (etcd-02) had itself failed a check 35 s earlier.
- **The etcd members were not in trouble when the checks failed.** Each had ≤ 20 % node CPU and ≤ 0.92 cores of etcd process CPU. WAL fsync was ≤ 2.4 ms, backend commit ≤ 6.4 ms and peer RTT ≤ 7 ms. There was no leader change, and only +2 / +4 failed proposals on etcd-02 / etcd-03.
- **The health checks mostly fail when the CP node is saturated (90–98 % CPU here), and recover within 5–10 s.** Run 03's cp-03 failover at 53 % CPU shows this is not the whole story. Either way, the probe timeout is too tight under load. In this setup, it is the failover itself that turns a slow probe into client-visible errors.

### 3. etcd reads are now spread across all three members

Because of cp-01's failovers, the three API servers ended up on three different etcd members. Peak range rates were 1,548 / 1,499 / 1,510 per second. In runs 02 and 03, etcd-03 served 2–3 times more reads than the others. etcd-03 had +1 slow apply (+168 in run 03), and etcd-01 had a maximum of 8 pending proposals. The DB file grew from 143 to 669 MiB, with 203 MiB in use. etcd RSS stayed at ≤ 1.1 GiB.

This was a side effect of the failovers. With the RKE2 load balancer, how reads are spread across members is decided by which member each node happens to be pinned to.

### 4. APF, KCM, cleanup and memory

- **APF:** 2,099 rejections, none during creation, all during remove-services / remove-configs (09:43:43–09:44:29):
  - 2,096 WATCH 429s from `kube-system-service-accounts` (`workload-high`, queue-full): 512 on cp-01, 552 on cp-02 and 1,032 on cp-03.
  - 3 POST rejections on cp-02 in `system-nodes` (`time-out`). This is the first rejection in the `system` priority level in this series. It is minor, but it was a node's request.
- **KCM (cp-01):**
  - Rate-limiter wait means: PUT 63 ms, POST 39 ms.
  - 6,041 409 conflicts on PUT, the same as every run. 4 PUT 500s from the failovers.
  - Queue peaks: deployment 1,995 (patch), replicaset 1,238, endpoint_slice 858, GC `attempt_to_delete` 4,534, namespace 1,979.
- **Namespace cleanup: 12m06s**, against about 14 min in runs 01–03. The namespace queue had the same depth (1,979). The difference matches the lower load on cp-01, which serves the KCM's deletes, but one run is not enough to be sure.
- **Memory:** API server RSS peaked at 8.7 / 8.6 / 7.7 GiB, close to what you would expect with the watches spread over three servers.

## Recommendations

1. **Stop using the RKE2 etcd load balancer for kube-apiserver.** This is now the top item.
   - Set `kube-apiserver-arg: etcd-servers=https://<etcd-01>:2379,https://<etcd-02>:2379,https://<etcd-03>:2379` on the CP servers. The etcd gRPC client then balances across members and retries per request, instead of losing every stream when a single health probe times out. It also spreads reads by design.
   - Test it on one CP first. RKE2 sets the flag itself, so check that the client certificate paths still resolve and that the override persists across `rke2-server` restarts.
2. **Add CP capacity before raising the load.** All three API servers are now saturated (5.6–5.9 cores, 92–98 % node CPU) at about 27 Services/s. Going to 12–16 vCPU per CP node, or adding a fourth CP, also gives the health probes headroom. That reduces the failovers even if recommendation 1 is not adopted.
3. **Keep balancing as part of the run procedure.** It removed the lopsided Service latencies seen in runs 02 and 03. Before each run, check that goroutines are within about 10 % across the three servers, as here.
4. **Unchanged from earlier runs:**
   - downsize etcd to 4 vCPU / 8 GiB (≤ 20 % CPU and ≤ 1.1 GiB RSS)
   - defragment before every run
   - spread the CP and etcd VMs across Harvester hosts (u2 and u10 each host a CP and an etcd member)
   - raise `concurrent-namespace-syncs` for the 12–14 min cleanup
