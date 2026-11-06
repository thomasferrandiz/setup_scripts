# Split control plane, run 07 — api-intensive, 2000 iterations, QPS 150 / burst 200

Results: `results-api-intensive-20261105T172230Z-FJZfw8`. The settings and topology are the same as [run 06](./run_06_analysis.md), with one change:
- `ITERATIONS=2000 QPS=150 BURST=200 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`;
- 3 control-plane nodes (16 vCPU / 16 GiB) and 3 dedicated etcd nodes (8 vCPU / 16 GiB);
- 1,000 workers;
- **New: kube-apiserver connects directly to the etcd members.** The flag is `--etcd-servers=https://192.168.66.2:2379,https://192.168.65.97:2379,https://192.168.66.251:2379`, set by `use-direct-etcd.sh`. Before this, it went through the RKE2 etcd load balancer on `127.0.0.1:2379`.

Preparation followed run 06's recommendation 2 (rebalance, wait, defrag, run):
- **16:08–16:10:** `use-direct-etcd.sh` restarted `rke2-server` on cp-01, cp-02 and cp-03.
- **16:11–16:13:** rebalance; all Cilium pods were recreated. **The 1,000 `rke2-traefik` pods were not restarted** and date from Nov 4.
- **17:22:17–17:22:21:** defrag, about 1 s per member.
- **17:22:48:** kube-burner start.

Cluster state at start:
- **Stored objects:** 10.6k (40.9k in run 06). The rebalance Events had expired.
- **etcd DB:** 128 MiB, all of it in use (947 MiB in run 06). It grew to 638 MiB during the run.
- **Goroutines:** 55.4k / 41.2k / 23.2k (cp-01 / cp-02 / cp-03). **This is the most uneven start of the series** (run 06: 38.4k / 38.9k / 41.0k).
- **API server RSS:** 7.5 / 6.2 / 4.6 GiB.
- **Leaders:** etcd-01 led throughout, with no leader changes. The KCM leader was cp-01.

## Verdict

**Direct etcd connections removed run 06's main error source.**
- API server 5xx fell from 112 to **2**.
- kube-burner errors fell from 33 creates + 90 patches to **1 create**, which was retried.
- There were no failover storms. When a single etcd connection broke, only the request using it failed; the other ~130 connections from that API server to each member were unaffected.

**Two smaller problems remain. Both are on cp-01, which started with 55k goroutines against cp-03's 23k.**

1. **997 APF 429s for Service WATCH on cp-01 at 17:35, during remove-configs.**
   - cp-01's watch cache force-closed slow Service watchers (`apiserver_terminated_watchers_total{resource="services"}`: **15,892 on cp-01**, 1,047 on cp-02, 0 on cp-03).
   - The watchers re-watched together. Most of them are the `rke2-traefik` DaemonSet, whose service account in `kube-system` falls into the single-flow `kube-system-service-accounts` FlowSchema. That flow's queue filled (finding 2).
   - This is the same trap Cilium hit before it got its own FlowSchema.
2. **Two etcd requests failed with `read: connection timed out`**, at 17:23:24 and 17:35:01.
   - Each time, one TCP connection from cp-01 to an etcd member went about 10 s without acknowledgment.
   - The etcd members logged nothing at those times (finding 3).

**The load imbalance drives the remaining pod-latency tail.**
- Pod Ready p99 was 6 s and max 16 s (5 s / 6 s in run 06).
- cp-01 was at 73 % node CPU during creation and 92 % at 17:35. cp-03 peaked at 44 %.
- Mean Service POST took 8.4 s on cp-01 and **0.09 s** on cp-03.

## Comparison

| | split run 05 | split run 06 | **split run 07** |
|---|---|---|---|
| API server → etcd | RKE2 etcd proxy | RKE2 etcd proxy | **direct (3 endpoints)** |
| Before the run | (rebuilt cluster) | defrag, then rebalance | **restarts, rebalance, wait 1 h, defrag** |
| Stored objects / etcd DB at start | 8.7k / 94 MiB | 40.9k / 947 MiB | **10.6k / 128 MiB** |
| Goroutines at start | 37.7k / 36.9k / 43.7k | 38.4k / 38.9k / 41.0k | **55.4k / 41.2k / 23.2k** |
| kube-burner errors | 0 | 33 create + 90 patch | **1 create (retried)** |
| API server 5xx (creation / total) | 1 / 9 | 111 / 112 | **1 / 2** |
| API server 429s | 0 | 0 | **997 (cp-01, Service WATCH)** |
| etcd failovers / broken etcd connections | 1 | 6 | **0 / 2** |
| Iteration 1,800 / waiting for actions | 71 s / 81 s | 71 s / 87 s | 72 s / 81 s |
| Job duration | 1m53s | 1m55s | 1m55s |
| Service creates per server | 803 / 477 / 720 | 706 / 884 / 419 | **556 / 0 / 1,445** |
| Mean Service POST, creation | 3.5 / 1.6 / 4.5 s | 8.6 / 7.7 / 4.4 s | **8.4 / – / 0.09 s** |
| Mean ClusterIP allocation, creation | 58 / 57 / 65 ms | 61 / 68 / 59 ms | 99 / – / 19 ms |
| Allocator busy, peak window | 53 / 45 / 47 % | 74 / 74 / 8 % | 74 / 0 / 39 % |
| API server process CPU, peak window | 7.6 / 6.7 / 7.3 cores | 8.1 / 7.3 / 7.3 cores | 8.8 / 7.1 / 4.6 cores |
| API server → etcd create latency, creation | 38 / 52 / 62 ms | 47 / 71 / 46 ms | 69 / 45 / **14** ms |
| Peak CP node CPU (creation) | 71 / 61 / 59 % | 71 / 63 / 66 % | 73 / 62 / 44 % (**92 %** cp-01 at 17:35) |
| Peak etcd node CPU | ≤ 16 % | ≤ 16 % | ≤ 21 % |
| Pod Ready p99 / max / avg | 7 / 24 / 3.0 s | 5 / 6 / 3.1 s | **6 / 16 / 3.1 s** |
| PodScheduled p99 / Initialized p99 | 1.6 s / 1 s | 2.1 s / 2 s | 2.9 s / 2 s |
| APF `system` queued (max) | 58 (cp-03) | 0 | 0 |
| Read / patch | 5m41s / 2m58s | 5m39s / 2m58s | 5m40s / 2m58s |
| remove-deployments / services / configs | 18 / 18 / 33 s | 19 / 21 / 31 s | 18 / 21 / 30 s |
| API server peak RSS | 6.0 / 6.1 / 6.6 GiB | 8.1 / 7.9 / 8.3 GiB | 8.6 / 6.8 / 5.2 GiB |
| Namespace cleanup | 13m41s | 13m52s | 13m29s |

Triples are cp-01 / cp-02 / cp-03. The windows are aligned on the last server's sample:
- **Creation:** 17:22:49 → 17:24:24.
- **Peak:** 17:23:31 → 17:24:24 (17:23:28 for cp-01).

kube-burner's connections went to cp-01 and cp-03 only, so cp-02 created no Services. Its 223 IPAddress POSTs came from the ClusterIP repair loop (finding 4).

## Findings

### 1. Direct etcd removed the failover storms

In run 06, a single failed 1 s `/ping` made the RKE2 etcd proxy drop all API server streams to a member, causing 111 500s. That mechanism is gone.
- Each API server now holds about 100–130 established connections to **each** member: 133 per member on cp-01, 103 on cp-02 and 109 on cp-03.
- There were 2 failed etcd requests in the whole run, both on cp-01:
  - **17:23:24**, Txn to etcd-02. It failed one Service create (`ipallocator.go: can not create IPAddress ... read tcp 192.168.71.1:48534->192.168.65.97:2379: read: connection timed out`). kube-burner retried it. It also produced 1 POST 500, 1 `etcd_request_errors_total{operation="create"}` and 2 ClusterIP allocation errors.
  - **17:35:01**, Txn to etcd-03. It caused 1 PUT 500 and 1 update error.
- cp-02 and cp-03 had no errors at all.
- KCM saw no new 500s. Its PUT 409 conflicts numbered 5,588, normal for this workload.

**Log noise, harmless:** every API server logs `addrConn.createTransport failed to connect to 192.168.66.2:2379 ... operation was canceled` about once a minute, starting from the restart.
- The long-lived clients are connected to etcd-01 (see the counts above).
- The noise most likely comes from a short-lived client that is closed while its first dial is still in flight.

### 2. Service watchers were force-closed on cp-01, and traefik's re-watches hit a single APF flow

**What happened at 17:35:**

| Time | Event |
|---|---|
| 17:34:30–17:35:31 | remove-services and remove-configs run. 2,000 Service deletions follow the 2,000 creations. |
| 17:35:05 | cp-01 node CPU reaches **92 %**. cp-02 is at 38 %, cp-03 at 16 %. |
| 17:35 sample | cp-01 rejects **997 WATCH requests with 429**: 962 services, plus configmaps, secrets, endpointslices and Traefik CRDs. |

The causes:
- Each Service event fans out to every Service watcher: about 1,006 Cilium agents, 1,000 traefik pods, plus CoreDNS and others. Live counts are 1,467 / 1,404 / 1,211 Service watches on cp-01 / cp-02 / cp-03.
- **The watch cache closes a watcher whose buffer stays full** (`apiserver_terminated_watchers_total{resource="services"}`):

  | | cp-01 | cp-02 | cp-03 |
  |---|---|---|---|
  | Service watchers closed since the 16:08–16:10 restarts | **15,892** | 1,047 | 0 |

  - The watch cache itself was never re-initialised (`apiserver_watch_cache_initializations_total` is 1).
  - cp-01 was the busiest server, so its watchers fell behind first.
- Closed watchers immediately re-list and re-watch.
  - Cilium has its own FlowSchema (`cilium`, `ByUser`) and priority level.
  - **traefik does not.** Its service account `kube-system:rke2-traefik` matches the stock `kube-system-service-accounts` FlowSchema. That FlowSchema distinguishes flows **by namespace**, so all 1,000 traefik pods share one flow and a handful of queues in `workload-high`.
  - The queue filled (in-queue max 12) and APF rejected the overflow with `queue-full`.
- The cumulative rejection counters show the same pattern before the run, during the restarts: 1,639 on cp-01 and 1,352 on cp-02. Live totals are now 18,087 / 12,630 / 0 for `kube-system-service-accounts`.
- kube-burner was not affected: traefik retries, and nothing in the benchmark uses ingress. The cost is CPU: re-lists of 2,000+ Services from 1,000 clients on a server that is already the busiest.

**Why the benchmark doesn't need traefik:** `rke2-traefik` is RKE2's default ingress controller. It is deployed as a DaemonSet on all 1,000 workers and watches Services, EndpointSlices, Secrets, ConfigMaps, Ingresses and about 15 Traefik CRDs. That makes it the second-largest watch population in the cluster, after Cilium.

### 3. Two 10-second TCP stalls between cp-01 and etcd

`read: connection timed out` is the kernel's `ETIMEDOUT`:
- The etcd client enables gRPC keepalive (30 s / 10 s), and gRPC sets `TCP_USER_TIMEOUT` to the keepalive timeout.
- So the error means that data sent on that connection went **10 s without a TCP acknowledgment**.

What we know:
- Both stalls happened at cp-01's busiest moments: creation at 17:23:24, and the 92 % CPU peak at 17:35:01. They were to two different members (etcd-02, then etcd-03).
- **The etcd members logged no warnings at all** at 17:23–17:24 or 17:34–17:35. The only slow requests were during the defrag at 17:22.
- etcd was idle:
  - CPU ≤ 21 %;
  - WAL fsync 1.3–1.6 ms, backend commit 2.9–3.5 ms;
  - peer RTT 2.4–2.6 ms;
  - 6 / 6 / 33 slow applies during the run, and no failed proposals.
- Pings from the CPs to the etcd nodes now average 0.2–1.5 ms, with occasional 5–14 ms spikes.
- Cumulative TCP timeouts since boot are higher on cp-01 (55k) than on cp-02 / cp-03 (35k / 36k). These counters include the whole uptime, so they only hint at a link-level or host-level problem.

The run 06 `/ping` failures and these stalls may have the same root cause, a Harvester host or network hiccup. Run 06's proxy turned each one into a storm; with direct connections, each costs one request. **This is not urgent.**

Also, cp-03's etcd create latency was 14 ms against cp-01's 69 ms, from the same etcd cluster. Most of the API server → etcd latency in this series is therefore client-side: API server CPU and goroutine scheduling, not etcd.

### 4. Load imbalance

The goroutine spread at start (55k / 41k / 23k) is the largest of the series. Effects during the run:

| | cp-01 | cp-03 |
|---|---|---|
| Node CPU during creation | 73 % | 44 % |
| Mean Service POST | 8.4 s | 0.09 s |
| Mean ClusterIP allocation | 99 ms | 19 ms |
| Mean POST across all resources | 0.32 s | 0.026 s |

- **Pod Ready max 16 s** (6 s in run 06), and patch Ready max 16 s.
- In the APF `system` level, cp-01 executed up to 25 requests and cp-03 up to 2. Nothing queued.

Where the imbalance comes from:
- The rebalance restarted Cilium (and the RKE2 agents) after the API server restarts, so Cilium was spread evenly.
- **traefik was not restarted.** Its 1,000 pods keep their connections, each carrying many watches, from wherever they landed during the three sequential restarts.
- `rebalance.sh` does not touch traefik.
- The run itself evened things out: goroutines live are now 43.5k / 40.9k / 36.0k.

**ClusterIP repair noise:** cp-01 logged 299 `repairip.go ... ClusterIP ... is not allocated; repairing`, and cp-02 made 223 IPAddress POSTs while creating no Services.
- The repair loop runs on every API server and checks Services against its IPAddress informer.
- During a burst of Service creation, it sees Services whose IPAddress has not reached its informer yet, and "repairs" them.
- This is harmless, but it is extra writes during the peak, and it is worst on the most loaded server.

### 5. Everything else

- **Throughput:** client-bound, as before. Iteration 1,800 came at 72 s, the job took 1m55s, and read and patch timings are unchanged.
- **APF:** apart from finding 2, cp-01 had up to 12 requests in queue in `workload-high` (`kube-system-service-accounts`) and 5 for `kube-scheduler`.
- **KCM (cp-01):** 5,588 PUT 409s and no new 500s.
- **etcd:**
  - no leader changes;
  - DB 128 → 638 MiB during the run;
  - RSS and CPU as low as before.
- **Cleanup:** removes took 18 / 21 / 30 s. Namespace cleanup took 13m29s.

## Recommendations

1. **Keep direct etcd.** The tofu configuration (`bench_etcd` and `etcd-servers` in `server-cloud-config.yml`) already makes it the default for rebuilt clusters.
2. **Remove traefik from the benchmark cluster.** It is unused here and adds 1,000 heavy watchers.
   - Add `disable: [rke2-traefik]` to the server config.
   - On the live cluster, set it in `/etc/rancher/rke2/config.yaml` on the servers, restart them one at a time, and check that the DaemonSet and HelmChart are removed.
   - If traefik must stay, give it its own FlowSchema and priority level with `distinguisherMethod: ByUser`, like `cilium-apf.yaml` in `rke2-server-sles.sh`.
   - **Implemented (traefik kept):** `rke2-server-sles.sh` installs `traefik-apf.yaml`: priority level `traefik` (20 shares, a hand of 8 queues of 500) and a FlowSchema at precedence 860 for `kube-system:rke2-traefik`. The live-cluster `kubectl apply` is in the kube-burner README.
3. **Check the balance before each run.** The rebalance only covers Cilium and the agents.
   - Before starting kube-burner, compare `go_goroutines` (or Service WATCH counts) across the CPs and require them to be within about 15 %.
   - If traefik stays, add a `rollout restart daemonset/rke2-traefik` to `rebalance.sh`.
   - **Implemented:** `rebalance.sh` restarts `rke2-traefik` after Cilium (`TRAEFIK=no` to skip). `rke2-server-sles.sh` writes a `rke2-traefik` HelmChartConfig with `maxUnavailable: 10%`, so the rollout takes minutes instead of hours (the chart default is 1 pod at a time).
4. **Watch for TCP stalls between the CPs and etcd during the next run.** This is cheap.
   - Take `nstat -az TcpExtTCPTimeouts TcpRetransSegs` deltas on the CPs and etcd nodes before and after.
   - Run a 1 s ping loop from cp-01 to the three members.
   - If the stalls follow cp-01 or one Harvester host, check where the VMs are placed (`kubectl get vmi -o wide` on Harvester).
5. **Unchanged from run 06:**
   - Enlarge `bench-net-01` to 4 vCPU / 8 GiB.
   - Then raise QPS to 200–250, with KCM `kube-api-qps` 200 / `kube-api-burst` 400.
   - Downsize etcd to 4 vCPU / 8 GiB: ≤ 21 % CPU.
   - Configure off-cluster etcd snapshots.
