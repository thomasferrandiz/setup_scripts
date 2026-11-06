# Split control plane, run 05 — api-intensive, 2000 iterations, QPS 150 / burst 200

Results: `results-api-intensive-20261105T101811Z-OAjv8y`. The settings are the same as [run 04](./run_04_analysis.md): `ITERATIONS=2000 QPS=150 BURST=200 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`. The topology is still 3 control-plane nodes and 3 dedicated etcd nodes with 1,000 workers, and the API servers still reach etcd through the RKE2 etcd load balancer (`127.0.0.1:2379`). Two things differ from run 04.

**Control-plane size.** The control-plane VMs now have **16 vCPU** (8 before) and 16 GiB. etcd nodes are unchanged at 8 vCPU / 16 GiB.

**A rebuilt cluster.** A `tofu apply` with the stacked default destroyed the etcd nodes on 2026-11-04. The servers were recreated, and the 1,000 workers rejoined with their agent state reset. The cluster therefore started from an empty etcd:
- 8.7k stored objects (40.9k in run 04)
- a 94 MiB DB (143 MiB)
- API server RSS of 4.3 / 3.9 / 4.8 GiB (7.8 / 7.9 / 7.0 GiB)

Some of the gains below come from this smaller state, not from the CPUs.

Cluster state at start:
- **Goroutines:** 37.7k / 36.9k / 43.7k (cp-01 / cp-02 / cp-03). cp-03 is 18 % above the others, outside the 10 % balance target. **The agents were not rebalanced after the rebuild.** A scan of the 1,000 workers after the run found that the kubelets use cp-03 for 496 workers, cp-01 for 259 and cp-02 for 245.
- **etcd:** etcd-01 was the leader for the whole run, with no leader changes.
- **KCM leader:** cp-01.

## Verdict

**This is the cleanest run of the series: 0 kube-burner errors and 0 APF rejections.** It is also the first time the API servers kept up with the client.
- Mean Service POST fell from 7.6 / 13.2 / 10.9 s to **3.5 / 1.6 / 4.5 s**.
- ClusterIP allocators were at most 53 % busy (52 / 90 / 83 % in run 04).
- Service creates drained 10 s after the last iteration (23 s in run 04).
- Peak control-plane node CPU was 71 / 61 / 59 % of 16 vCPU, which leaves headroom.

**The creation phase is now limited by the client** (QPS 150, about 37 iterations/s), not by the API servers. The job time is unchanged (1m53s).

There are two blemishes:
1. **Pod Ready max 24 s and p99 7 s** (6 s and 4 s in run 04). Containerd and Cilium were not the cause: all 4,000 sandboxes started within 5 s, as in run 04. Kubelet requests on the overloaded cp-03 queued in APF: see [finding 2](#2-the-pod-latency-tail-kubelets-piled-on-cp-03).
2. **One active etcd load-balancer failover**, on cp-03 at 10:30:32 during remove-services. It closed 103 connections and caused 7 server-side 500s and 2 lease 504s. kube-burner retried through them, so no client error was reported. Health checks still fail at only 50–70 % node CPU, so more CPU alone has not removed the failovers.

## Comparison

| | split run 03 | split run 04 | **split run 05** |
|---|---|---|---|
| CP size | 8 vCPU | 8 vCPU | **16 vCPU** |
| Stored objects at start | — | 40.9k | **8.7k (rebuilt cluster)** |
| Goroutines at start | 45.6k / 44.3k / 28.3k | 40.4k / 40.3k / 37.3k | 37.7k / 36.9k / 43.7k |
| kube-burner errors | 0 | 13 | **0** |
| API server 5xx (creation / total) | 0 / 12 | 39 / 39 | **1 / 9** (all cp-03) |
| Active etcd failovers during the run | 1 | 2 | 1 (cp-03, remove-services) |
| Iteration 1,800 / waiting for actions | 69 s / 88 s | 68 s / 91 s | 71 s / **81 s** |
| Job duration | 2m02s | 1m54s | 1m53s |
| Service creates per server | 484 / 410 / 1,106 | 244 / 890 / 868 | 803 / 477 / 720 |
| Mean Service POST, creation | 17.5 / 5.5 / 0.12 s | 7.6 / 13.2 / 10.9 s | **3.5 / 1.6 / 4.5 s** |
| Mean ClusterIP allocation, creation | 134 / 83 / 23 ms | 126 / 77 / 75 ms | **58 / 57 / 65 ms** |
| Allocator busy, peak window | 82 / 43 / 33 % | 52 / 90 / 83 % | **53 / 45 / 47 %** |
| API server process CPU, peak window | — | 6.8 / 6.1 / 6.4 cores | 7.6 / 6.7 / 7.3 cores |
| API server → etcd create latency, creation | 56 / 38 / 15 ms | 54 / 56 / 41 ms | 38 / 52 / 62 ms |
| Peak CP node CPU (creation) | 91 / 80 / 62 % | 98 / 93 / 92 % | **71 / 61 / 59 %** (of 16 vCPU) |
| Peak etcd node CPU | ≤ 18 % | ≤ 20 % | ≤ 16 % |
| Pod Ready p99 / max / avg | 4 / 5 / 2.6 s | 4 / 6 / 2.9 s | **7 / 24** / 3.0 s |
| PodScheduled p99 / Initialized p99 | 1.3 s / 1 s | 1.7 s / 1 s | 1.6 s / 1 s |
| Read / patch | 5m40s / 3m07s | 5m40s / 3m08s | 5m41s / 2m58s |
| remove-deployments / services / configs | 25 / 24 / 41 s | 20 / 22 / 40 s | **18 / 18 / 33 s** |
| APF rejections | 2,011 | 2,099 | **0** |
| API server peak RSS | 8.4 / 8.6 / 6.8 GiB | 8.7 / 8.6 / 7.7 GiB | 6.0 / 6.1 / 6.6 GiB |
| Namespace cleanup | 13m55s | 12m06s | 13m41s |

Triples are cp-01 / cp-02 / cp-03. Scrapes came every 40–60 s and were up to 4 s apart between servers, so the windows are aligned on the last server's sample:
- **Creation:** 10:18:32 → 10:20:14.
- **Peak:** 10:19:14 → 10:20:14.
- **Run 04 equivalents:** 09:31:07 → 09:32:47 and 09:31:52 → 09:32:47.

## Findings

### 1. With 16 vCPU, the API servers keep pace with the client

kube-burner sent iterations 200 → 1,800 between 10:19:00 and 10:19:42, the same 37 iterations/s as every run.

Creation window:

| Server | Service POSTs | Mean POST | Mean allocation | Allocator busy (peak) | etcd create | Process CPU (peak) | All POSTs |
|---|---|---|---|---|---|---|---|
| cp-01 (KCM leader) | 803 | 3.5 s | 58 ms | 53 % | 38 ms | 7.6 cores | **25,259** |
| cp-02 | 477 | 1.6 s | 57 ms | 45 % | 52 ms | 6.7 cores | 6,860 |
| cp-03 | 720 | 4.5 s | 65 ms | 47 % | 62 ms | 7.3 cores | 9,655 |

- **Allocation cost fell from 75–126 ms to 57–65 ms, and the allocators are no longer the bottleneck.**
  - In the peak window, 1,425 Services were allocated. That is about 24/s over the 60 s window (about 27/s in run 04), but here the servers ran out of work: the Service tail after iteration 1,800 shrank from 23 s to 10 s.
  - Each server uses only about 1 core more than in run 04 (7.6 / 6.7 / 7.3 against 6.8 / 6.1 / 6.4). The gain comes from no longer competing for CPU: node CPU went from 92–98 % to 59–71 %.
  - In run 04, the API server, KCM, kubelet and Cilium agent on each node were all fighting over 8 vCPU.
- **The remaining POST latency (1.6–4.5 s) is queueing behind the client burst, not saturation.** With QPS 150 and burst 200, kube-burner sends requests in bursts, and Services wait behind them.
- HAProxy `leastconn` sent cp-02 the fewest Service creates (477). Unlike run 04, the KCM leader cp-01 got the most (803), because its extra load no longer slows it down.
- **Part of the gain may come from the rebuilt cluster.** With 4.7 times fewer stored objects, list and watch-cache work is lighter: etcd served 239 / 357 / 472 range requests/s during creation, against 784 / 1,013 / 1,181 in run 04. A run on a cluster that has been through a few benchmarks will show how much of the gain is due to the CPUs.
- **The KCM is now at its client limit.** Its rate-limiter wait rose to 64 ms for PUT and 16 ms for POST (12 / 3 ms in run 04). Pod creation is held back by this limit, not by the API servers. The replicaset queue peaked at 1,098.

### 2. The pod latency tail: kubelets piled on cp-03

Pod Ready had a p99 of 7 s and a maximum of 24 s.

**Containerd and Cilium were ruled out.** The containerd logs of all 1,000 workers show every one of the 4,000 sandboxes of the run (creation and patch rollout) completing within 5 s, with no failures. Sandboxes started in namespace order. Only one was more than 4 s later than its neighbours: `api-intensive-496` on `bench-wk-480`, 20 s late.

That pod's kubelet log:

```
10:19:15  VerifyControllerAttachedVolume configmap / secret     (pod received)
10:19:17  Couldn't get configMap api-intensive-496/configmap-1: failed to sync configmap cache: timed out waiting for the condition
10:19:17  … retry in 0.5 s, then 1 s, 2 s, 4 s, 8 s
10:19:36  volumes mounted, sandbox started
10:19:42  podStartE2EDuration=27.2s
```

The kubelet watches each ConfigMap and Secret its pods mount, so every pod start opens a LIST and a WATCH per object in the `system-nodes` flow. When the first sync took more than about 1 s, the volume manager's exponential backoff turned a short delay into 20 s.

**What caused the slow syncs:**
- 50 workers logged 170 of these sync timeouts during the run, and **46 of those workers are served by cp-03**.
- cp-03 carries 496 of the 1,000 kubelets.
- During creation, cp-03's `system` priority level had up to **43 requests executing and 58 queued**. The other two servers queued nothing, and run 04 (balanced workers) queued nothing.

Most affected pods recovered at the early retries, which fits the p99 of 7 s. `bench-wk-480` was the only one that needed the full backoff.

This is a balancing problem, not a capacity problem. The workers rejoined one batch at a time after the rebuild, and nobody ran [rebalance.sh](../../kube-burner/rebalance.sh) afterwards.

### 3. etcd load-balancer health checks still fail at 50–70 % CPU

`rke2-server` journals, with active-member events in bold:

| Time | Node | Event |
|---|---|---|
| 10:19:01–10:19:58 | cp-03 | etcd-02 and etcd-01 (standby) FAILED → PREFERRED, three times |
| 10:19:39 | cp-02 | etcd-02 (standby) FAILED, recovered at 10:19:54 |
| 10:30:13 | cp-01 | etcd-01 (standby) FAILED |
| 10:30:31 | cp-03 | etcd-01 (standby) FAILED |
| **10:30:32** | **cp-03** | **etcd-03 ACTIVE → FAILED, closing 103 connections; etcd-02 ACTIVE** |
| 10:30:40 | cp-02 | etcd-02 (standby) FAILED |
| 10:31:22 | cp-01 | etcd-03 (standby) FAILED |

The failover's effects, all on cp-03:
- 8 etcd request errors (5 update, 1 get, 1 create, 1 delete). The get error and one lease 504 came during creation; the rest came during remove-services.
- 3 PUT, 1 PATCH, 1 POST, 1 DELETE and 1 GET 500.
- 2 lease PUT 504s, at 10:19 and 10:30–10:31.

kube-burner was patching Services and ConfigMaps at the time and retried transparently, so it reported no errors.

**Compared with run 04:**
- There was one active failover instead of two.
- Probe failures no longer require a saturated node. The checks failed at 59–71 % node CPU during creation, and at 22–60 % during the removes.
- The etcd members were healthy throughout:
  - ≤ 16 % node CPU and ≤ 0.25 etcd cores during creation
  - WAL fsync ≤ 2.1 ms, backend commit ≤ 5.5 ms, peer RTT ≤ 2.9 ms
  - no leader change and 3 failed proposals

  etcd-02 and etcd-03 logged 64 and 117 slow applies. They came during read, patch and removes, not during creation, on top of counters already high from the worker rejoin.

**More CPU halved the failovers but did not remove them. The probe of the RKE2 etcd load balancer is still the only source of server-side errors in this topology.**

### 4. APF, KCM, cleanup and memory

- **APF: no rejections at all**, against 2,011–3,298 429s in each of runs 02–04, all during remove-services and remove-configs. The removes were also faster (18 / 18 / 33 s against 20 / 22 / 40 s). The only queueing was cp-03's `system` level during creation (finding 2) and up to 5 requests in `workload-high` on cp-01.
- **KCM (cp-01):**
  - 6,069 409 conflicts on PUT, as in every run. No 500s, against 15 in run 04.
  - Queue peaks: deployment 1,992, replicaset 1,098, endpoint_slice 507, endpoint 711, GC `attempt_to_delete` 4,765, namespace 1,978.
- **Namespace cleanup: 13m41s**, back to the 14 min of runs 02 and 03. Run 04's 12m06s was the outlier. Cleanup is bound by the KCM: control-plane CPU stayed at 5–14 %.
- **Memory:** API server RSS peaked at 6.0 / 6.1 / 6.6 GiB, 2 GiB below run 04 because the cluster holds fewer objects. etcd DB went from 94 to 639 MiB, all in use; etcd RSS stayed ≤ 0.93 GiB.

## Recommendations

1. **Rebalance before the next run.** Run `rebalance.sh` (kubelets and Cilium), then check that goroutines and kubelet connections are within about 10 % across the three servers. This removes the pod latency tail of finding 2. Count kubelet connections per server with `ss -tnp | grep 6443` on the workers, or check the goroutines.
2. **Stop using the RKE2 etcd load balancer for kube-apiserver** (unchanged from run 04): `kube-apiserver-arg: etcd-servers=https://<etcd-01>:2379,https://<etcd-02>:2379,https://<etcd-03>:2379`. Run 05 shows that the probes fail even with CPU headroom, so this is the only fix left for the remaining errors.
3. **Raise the load to find the new limit.** At QPS 150, the 16-vCPU control plane is client-bound. Run QPS 200–250, with burst at least the QPS. Raise the KCM's `kube-api-qps` (100 → 200) and `kube-api-burst` (200 → 400) at the same time, since it is now at its limit.
4. **Repeat one run at QPS 150 after a few runs.** This separates the gain from 16 vCPU from the gain from the smaller, rebuilt cluster (8.7k objects against 40.9k).
5. **Unchanged:**
   - Downsize etcd to 4 vCPU / 8 GiB (≤ 16 % CPU, ≤ 0.93 GiB RSS).
   - Defragment before each run.
   - **Configure off-cluster etcd snapshots (S3 or a Longhorn backup target).** There were none when the cluster was destroyed.
