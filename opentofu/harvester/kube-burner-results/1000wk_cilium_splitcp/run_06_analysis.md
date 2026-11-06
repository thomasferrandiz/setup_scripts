# Split control plane, run 06 — api-intensive, 2000 iterations, QPS 150 / burst 200

Results: `results-api-intensive-20261105T124010Z-HQo8uW`. The settings and topology are the same as [run 05](./run_05_analysis.md):
- `ITERATIONS=2000 QPS=150 BURST=200 PRE_CREATE_NAMESPACES=true`, `NODE_SAMPLE_COUNT=5`;
- 3 control-plane nodes (16 vCPU / 16 GiB) and 3 dedicated etcd nodes (8 vCPU / 16 GiB);
- 1,000 workers;
- API servers reach etcd through the RKE2 etcd load balancer (`127.0.0.1:2379`).

Before the run, `defrag-etcd.sh` and then `rebalance.sh` were run:
- **11:43:19–11:43:22**: defrag, each member 670 → 98 MB.
- **11:43–11:45**: rebalance. All Cilium pods were recreated and the agents reconnected.
- **12:40:31**: kube-burner trigger, 55 minutes later.

Cluster state at start:
- **Goroutines:** 38.4k / 38.9k / 41.0k (cp-01 / cp-02 / cp-03), within 7 %. The rebalance worked; run 05 had 37.7k / 36.9k / 43.7k.
- **Stored objects:** 40.9k (8.7k in run 05). These are mostly Events from the rebalance, which expire after 1 h. At 14:20 there were 0 Events left.
- **etcd DB: 947 MiB, of which 124 MiB in use.** The rebalance churn after the defrag had grown the file 10-fold again, so the defrag did not help this run (finding 4).
- **API server RSS:** 7.3 / 7.1 / 7.6 GiB (4.3 / 3.9 / 4.8 GiB in run 05).
- **Leaders:** etcd-01 led throughout, with no leader changes. The KCM leader was cp-01.

## Verdict

**The rebalance removed run 05's pod-latency tail.**
- Pod Ready p99 5 s, max 6 s (7 s and 24 s in run 05).
- No APF queueing at the `system` level.
- No 429s.

**Errors are back, from two unrelated causes. Neither is a capacity limit.**

1. **Six active etcd load-balancer failovers in 42 s, during creation, two on each CP.**
   - They produced 111 API server 500s and 33 kube-burner create errors (`rpc error: code = Unavailable desc = error reading from server: EOF`).
   - kube-burner retried them all, and the object verification passed.
   - CP node CPU was only 34–36 % when they started, and the etcd nodes were at 6–16 %.
   - The RKE2 probe behind these failovers turns out to be a single **1-second HTTP `/ping` to the etcd node's RKE2 supervisor**, not an etcd health check (finding 2).
2. **90 PATCH errors at 12:49:13** (`http2: client connection force closed via ClientConn.Close`). This is the same one-connection loss as haproxy runs 11, 13, 14 and 16.
   - HAProxy shows that **cp-02 closed kube-burner's busy connection** (`SD`) 3.4 s into the patch job.
   - At that moment the 1-vCPU bench VM was opening about 800 TLS connections (finding 3).

Creation throughput is unchanged: iteration 1,800 came at 71 s and the job took 1m55s. Service POSTs were slower than in run 05 (4.4–8.6 s against 1.6–4.5 s), because of the failovers and the larger cluster state.

## Comparison

| | split run 04 | split run 05 | **split run 06** |
|---|---|---|---|
| CP size | 8 vCPU | 16 vCPU | 16 vCPU |
| Before the run | defrag | (rebuilt cluster) | **defrag, then rebalance** |
| Stored objects / etcd DB at start | 40.9k / 143 MiB | 8.7k / 94 MiB | 40.9k / **947 MiB** (124 in use) |
| Goroutines at start | 40.4k / 40.3k / 37.3k | 37.7k / 36.9k / 43.7k | **38.4k / 38.9k / 41.0k** |
| kube-burner errors | 13 | 0 | **33 create (all retried) + 90 patch** |
| API server 5xx (creation / total) | 39 / 39 | 1 / 9 | **111 / 112** |
| Active etcd failovers during the run | 2 | 1 | **6 (all during creation)** |
| Iteration 1,800 / waiting for actions | 68 s / 91 s | 71 s / 81 s | 71 s / 87 s |
| Job duration | 1m54s | 1m53s | 1m55s |
| Service creates per server | 244 / 890 / 868 | 803 / 477 / 720 | 706 / 884 / 419 |
| Mean Service POST, creation | 7.6 / 13.2 / 10.9 s | 3.5 / 1.6 / 4.5 s | 8.6 / 7.7 / 4.4 s |
| Mean ClusterIP allocation, creation | 126 / 77 / 75 ms | 58 / 57 / 65 ms | 61 / 68 / 59 ms |
| Allocator busy, peak window | 52 / 90 / 83 % | 53 / 45 / 47 % | 74 / 74 / 8 % |
| API server process CPU, peak window | 6.8 / 6.1 / 6.4 cores | 7.6 / 6.7 / 7.3 cores | 8.1 / 7.3 / 7.3 cores |
| API server → etcd create latency, creation | 54 / 56 / 41 ms | 38 / 52 / 62 ms | 47 / 71 / 46 ms |
| Peak CP node CPU (creation) | 98 / 93 / 92 % | 71 / 61 / 59 % | 71 / 63 / 66 % |
| Peak etcd node CPU | ≤ 20 % | ≤ 16 % | ≤ 16 % |
| Pod Ready p99 / max / avg | 4 / 6 / 2.9 s | 7 / 24 / 3.0 s | **5 / 6 / 3.1 s** |
| PodScheduled p99 / Initialized p99 | 1.7 s / 1 s | 1.6 s / 1 s | 2.1 s / 2 s |
| APF `system` queued (max) | 0 | 58 (cp-03) | **0** |
| Read / patch | 5m40s / 3m08s | 5m41s / 2m58s | 5m39s / 2m58s |
| remove-deployments / services / configs | 20 / 22 / 40 s | 18 / 18 / 33 s | 19 / 21 / 31 s |
| APF rejections | 2,099 | 0 | **0** |
| API server peak RSS | 8.7 / 8.6 / 7.7 GiB | 6.0 / 6.1 / 6.6 GiB | 8.1 / 7.9 / 8.3 GiB |
| Namespace cleanup | 12m06s | 13m41s | 13m52s |

Triples are cp-01 / cp-02 / cp-03. The windows are aligned on the last server's sample:
- **Creation:** 12:40:29 → 12:42:12.
- **Peak:** 12:41:14 → 12:42:12 (12:41:10 for cp-01).

## Findings

### 1. The rebalance fixed the pod-latency tail

- The `system` priority level (kubelets) executed at most 16 / 5 / 29 requests, with nothing queued. In run 05, cp-03 had 43 executing and 58 queued.
- Pod Ready max fell from 24 s to 6 s, and p99 from 7 s to 5 s, so it is back to run 04 levels.
- The patch rollout had a Ready p99 of 3.5 s.
- Goroutines are within 7 % across the servers.

**Run `rebalance.sh` after anything that reconnects the agents**, such as a server rebuild, an API server restart or a rejoin.

### 2. Six etcd failovers, and what the RKE2 probe actually checks

`rke2-server` journals for active-member events (etcd-01 = 192.168.66.2, the leader; etcd-02 = 192.168.65.97; etcd-03 = 192.168.66.251):

| Time | Node | Event |
|---|---|---|
| 12:41:06 | cp-02 | **etcd-02 ACTIVE → FAILED**, closing 103 connections → etcd-03 |
| 12:41:20 | cp-03 | **etcd-02 ACTIVE → FAILED**, closing 104 connections → etcd-03 |
| 12:41:28 | cp-01 | **etcd-02 ACTIVE → FAILED**, closing 137 connections → etcd-03 (etcd-01, standby, had failed 1 s earlier) |
| 12:41:30 | cp-01 | **etcd-03 ACTIVE → FAILED**, closing 133 connections; back on etcd-03 at 12:41:37 |
| 12:41:36 | cp-02 | **etcd-03 ACTIVE → FAILED**, closing 102 connections → etcd-02 |
| 12:41:48 | cp-03 | **etcd-03 ACTIVE → FAILED**, closing 101 connections → etcd-02 |

Standby failures (no effect):
- cp-01 etcd-03 at 12:41:09;
- cp-02 etcd-01 at 12:41:47 and 12:52:36;
- cp-02 etcd-03 at 12:42:17.

Each failed member recovered at the next successful check, 6–9 s later.

Effects:
- **111 API server 500s**: cp-01 82, cp-02 14, cp-03 15. They all came between 12:41:06 and 12:42:12, plus one lease 504 at 12:53.
- 118 etcd request errors in the API servers' etcd clients (88 / 14 / 16).
- 34 failed proposals on etcd-02 and etcd-03.
- 32 KCM 500s.
- **33 kube-burner create errors** (15 Deployments, 9 Services, 5 Secrets, 4 ConfigMaps; 4 of them inside ClusterIP allocation).
  - All were retried.
  - 28 retries found the object already created.
  - "Verifying created objects" passed.

**What the probe checks.** The probe comes from the k3s source (`pkg/etcd/etcdproxy.go`, `createHealthCheck`).
- Every 5–10 s (5 s with jitter), the `rke2-server` process on the CP node sends `GET https://<etcd node>:9345/ping`. That is the RKE2 supervisor on the etcd node, not etcd.
- The timeout is **1 second**.
- **A single failed or slow `/ping` marks the member FAILED.** If that member is active, the load balancer closes every API server → etcd connection through it.
- Neither the timeout nor the threshold can be configured.

**Why it fails here:**
- **The probes failed against all three members, from all three CPs, and only while the CPs were busy.** Apart from cp-02's 12:52:36 standby failure, during the removes, all failures came in creation (12:41:06–12:42:17).
- **The etcd nodes were idle:** 6–16 % CPU, 0.4–0.7 etcd cores, WAL fsync 1.8–2.5 ms, backend commit 4–6 ms, no leader change.
- **The CP nodes were at 34–36 % CPU when the failures started**, and 63–71 % at the peak.
- So the slow part is on the CP side. A `/ping` round trip over a reused keep-alive connection takes more than 1 s. Two parts of the CP could be responsible:
  - **the `rke2-server` process**, which also proxies every API server ↔ etcd byte through the same Go TCP load balancer;
  - **the CP VM's network path.** etcd peer RTT is 3.2–3.5 ms between idle VMs, which is high for a LAN.
- **Run 05 had 1 failover under the same CPU, run 06 had 6.** With a 1 s threshold and a single sample, this is a matter of chance. Doubling the CP CPU (run 04 → 05) did not remove it.

**The fix is to take this probe out of the data path,** in recommendation 1.

### 3. The patch-job errors: cp-02 closed kube-burner's connection in the middle of a dial storm

The patch job started at 12:49:06 and listed the 2,000 Deployments.

At 12:49:13, 90 PATCHes failed together with `http2: client connection force closed via ClientConn.Close`. kube-burner logged them and moved on, so 90 of the 6,000 Deployment patches were not applied. The job still took the usual 2m58s.

**HAProxy log on lb-01** (client `192.168.70.164` = bench-net-01):
- **12:49:09.0–12:49:13**: about 790 new TLS connections from kube-burner to all three servers, open 0.5–2 s each and 2.6 KB each (just a handshake). About 200 were closed by the client (`CD`).
  - Every kube-burner job start does this. Run 05's patch start opened about 420 and had no errors, and creation start opened about 330.
  - With HTTP/2 negotiated after TLS, Go's `net/http` dials one connection for each request that finds no ready connection, and then drops the duplicates.
- **12:49:09.569 → 12:49:12.926**: connection `:60354` to **cp-02** carried 567 KB of PATCH traffic and ended with **`SD`**: closed by the server side during the data phase.
- There was no 5xx and no API server log entry at that time.

**Why this produces "force closed".** In Go's HTTP/2 client, `ClientConn.Close` is called after a **write error** on the connection (`cc.werr`). A missed ping gives a different error, `client connection lost`, so run 16's ping hypothesis does not fit.

**The most likely sequence:**
1. kube-apiserver's `goaway-chance=0.001` sent a graceful GOAWAY on that connection. At 150 QPS that happens about every 7 s.
2. Go's HTTP/2 server waits for the open streams to finish, then closes 1 s later.
3. The client kept sending new PATCH frames because it had not yet processed the GOAWAY. A 1-vCPU VM busy with hundreds of TLS handshakes reacts slowly.
4. The kernel answered the late writes with an RST. The client's write failed, and Go closed the whole connection with its 90 in-flight streams.

This matches the earlier failures: runs 11, 13, 14 and 16 all lost one connection **at the start of a job**, which is when the dial storms happen. Runs 11 and later all had `goaway-chance` enabled. Nothing in the cluster was overloaded.

### 4. Defrag before rebalance gives no benefit

| Time | etcd DB file | Stored objects |
|---|---|---|
| 10:44 (end of run 05) | 639 MiB | |
| 11:43 (defrag) | 98 MB | |
| 11:43–11:45 (rebalance) | | +32k (Events, 1 h TTL) |
| 12:40 (run 06 start) | **947 MiB** (124 MiB in use) | 40.9k |

Recreating about 1,000 Cilium pods and reconnecting the agents rewrote Nodes, Pods, CiliumEndpoints, CiliumNodes and Leases, and created about 32k Events. That grew the file from 98 MB to 947 MiB in under an hour.

**Impact:**
- etcd RSS 1.2 GiB at start (0.24 GiB in run 05).
- API server RSS about 3 GiB higher.
- The DB file did not grow during the run.

There is no measurable effect on etcd latency. The file is mostly free pages, and etcd's disk times were the same as in run 05.

### 5. Everything else

- **APF:** no rejections and no queueing, apart from up to 5 requests in `workload-high` on cp-01.
- **Throughput:**
  - kube-burner was again client-bound at about 37 iterations/s.
  - About 25 Services/s were allocated in the peak window.
  - The Service tail after iteration 1,800 was 16 s (10 s in run 05), because of the failovers.
  - The leastconn split moved during the run: cp-03 took 342 Service POSTs before 12:41:14 and only 77 after, while cp-01 took 0 before 12:41:10 and 706 after.
- **KCM (cp-01):**
  - 6,065 409 conflicts on PUT, as in every run.
  - 32 500s from the failovers.
  - Rate-limiter wait during creation: 51 ms PUT, 14 ms POST.
  - Queue peaks: GC `attempt_to_delete` 3,863, deployment 1,990, namespace 1,979, replicaset 1,222.
- **etcd:**
  - Slow applies: 0 / 23 / 62 on etcd-01 / etcd-02 / etcd-03, 7 of them during creation.
  - Pending proposals reached at most 16.
  - Range rate: 657 / 1,318 / 1,141 per second during creation.
- **Cleanup:** removes took 19 / 21 / 31 s. Namespace cleanup took 13m52s.

## Recommendations

1. **Point kube-apiserver directly at the etcd members.** This is the fix for finding 2, and it is now the main source of errors.
   - Set `etcd-servers=https://<etcd-01>:2379,https://<etcd-02>:2379,https://<etcd-03>:2379` in `kube-apiserver-arg` on the CP servers.
   - The etcd gRPC client then balances and retries per request, instead of losing about 100 streams whenever a 1 s `/ping` is late.
   - RKE2 replaces its default `--etcd-servers=https://127.0.0.1:2379` with the value from `kube-apiserver-arg`.
   - The API server's existing etcd client certificate works with every member, because each member's server certificate includes its node IP.
   - Tofu knows the etcd IPs, so `server-cloud-config.yml` can render them.
   - On the live cluster: edit `/etc/rancher/rke2/config.yaml` on each CP, then restart `rke2-server`, one node at a time, and rebalance afterwards.
   - To confirm the diagnosis first, run a `curl -k -m 1 -w '%{time_total}\n' https://<etcd>:9345/ping` loop on a CP during a run.
2. **Prepare the cluster in this order:** rebalance first, then wait, then defrag, then start the run.
   - Waiting at least 1 hour lets the rebalance Events expire. If you can't wait, delete the namespaced Events from the rebalance.
   - Defragmenting last starts the run with a compact DB (about 120 MiB instead of 947 MiB).
3. **Enlarge the bench VM** (`bench-net-01`, still 1 vCPU / 2 GiB) to 4 vCPU / 8 GiB, as run 16 suggested. Every job start opens hundreds of TLS connections at once, and a slow client turns a routine GOAWAY into a lost connection.
   - If the errors continue on a bigger VM, try a run with `goaway-chance` off to confirm the GOAWAY explanation.
   - kube-burner's patch job does not retry, so each lost connection costs up to 90 patches.
4. **Then raise the load** (QPS 200–250, KCM `kube-api-qps` 200 / `kube-api-burst` 400), as run 05 recommended. The control plane still has headroom: peak CP CPU was 63–71 %.
5. **Unchanged:**
   - Downsize etcd to 4 vCPU / 8 GiB (≤ 16 % CPU, ≤ 1.3 GiB RSS).
   - Configure off-cluster etcd snapshots.
