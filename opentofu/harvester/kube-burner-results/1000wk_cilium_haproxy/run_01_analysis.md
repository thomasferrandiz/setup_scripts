# haproxy + keepalived run 01: api-intensive, 2000 iterations

Run `results-api-intensive-20261026T101108Z`, on a new cluster with 3 control-plane nodes and 1000 workers. The API VIP is now served by haproxy (`balance leastconn`) and keepalived, replacing kube-vip in ARP mode. Everything else matches run 4 (`../1000wk_cilium_arpvip/run_4_analysis.md`): the same workload, 2000 iterations and the same phases.

## Verdict

The run was **clean**: kube-burner logged 0 errors, the API servers returned no 5xx, etcd had no failed proposals, and all 1003 nodes were Ready at the end. Spreading clients across the 3 API servers removed the single-node bottleneck that broke run 4.

## Comparison with run 4 (kube-vip ARP)

| | Run 4 (kube-vip) | haproxy 01 |
|---|---|---|
| kube-burner errors | 296 (Service delete timeouts) | **0** |
| Create loop (2000 iterations) | ~128 s (~14 it/s) | **~92 s (~22 it/s)** |
| POST latency during create | 88 → 939 ms | **23 – 59 ms** |
| API-server CPU usage | one server ~6–7 cores, the others idle | **~5–6 cores on each server during create**; 3.6k / 3.5k / 3.5k CPU-s over the run |
| API-server goroutines / RSS at start | 65k / 6.9 GiB on one server | 36k / 35k / 46k, 3.6–4.5 GiB each |
| remove-services | 50 s, 296 timeouts | **14 s, no errors** |
| API 5xx (504/500) | ~750 | **0** |
| APF rejections | 3,152, incl. 2,273 in `system-node-high` (heartbeats) | 8,877, **all** `kube-system-service-accounts` WATCH (`workload-high`) |
| etcd slow applies / failed proposals | 3,294 / 232 on cp-01 | 103 / 740 / 639, **0 failed** |
| etcd apply lag (max) | 801 | 3 |
| Namespace cleanup | 14m09s | 12m48s |
| Pod Ready p99 (create) | 3 s | **23 s** (see below) |

The read (4m10s) and patch (12m39s) phases took the same time as in run 4, which suggests they are limited by the client.

## Details

### Create phase (10:11–10:13)
- 200 iterations every ~9.2 s, very steady. POST latency stayed below 60 ms with no APF queueing (`inqueue` was always 0), so the API servers were not the limit. The rate is probably set on the client side, by kube-burner's QPS or its workers.
- Each control-plane node was at 75–83% CPU. The load is now shared, but it is still high on each node. Most of it is probably the fan-out from watches (pods and endpoints to ~1000 kubelets and Cilium agents), which each API server handles for its own clients.

### Bulk delete burst (10:37:07–10:38:00)
- The control-plane nodes peaked at 85%, **100%** (cp-02) and 83% CPU at 10:37:48. In-flight mutating requests reached only 5–10.
- At their worst, POST and DELETE averaged 1.9 s and 1.1 s on cp-03 over a 30 s window, then returned to normal within one sample.
- 8.9k WATCH 429s were in `kube-system-service-accounts`, `queue-full`, at `workload-high` priority. These are kube-system agents (most likely Cilium) re-establishing watches after the Service and EndpointSlice churn. They retry, and there was **no** throttling of node heartbeats and no mass watch drop: goroutines stayed flat, while in run 4 they fell from 71k to 22k.
- etcd recorded slow applies in that window (740 on cp-02 and 639 on cp-03), with commit p99 at 32–64 ms. There were no failed proposals and no apply backlog.

### Namespace cleanup (10:38–10:51)
- Almost all of it goes through **bench-cp-01**: 490–730 req/s and 158k DELETEs, against 13k on cp-02 and 4k on cp-03. kube-controller-manager connects to its local API server, not the VIP, so its leader's node handles all namespace-deletion traffic. haproxy can't balance this. The rate is fixed by the controller's own client rate limit (same order as before, ~13 min).
- **16.5k `POST 403`** errors were spread over this window: a peak of ~7k/30 s at 10:38:51, then a steady ~3/s on cp-01. These are most likely creates rejected in terminating namespaces (`forbidden: ... being terminated`), for example from controllers recreating `kube-root-ca.crt` or events. They are expected and harmless, but the run didn't capture logs that would prove the cause.

### Remaining imbalances
- **Watches:** cp-03 holds ~30% more goroutines than the other two (46k against 35k). `leastconn` balances TCP connections, but clients multiplex many watches over one HTTP/2 connection, so the number of watches per server is not balanced. cp-03 also took most of the 429s (3.8k).
- **Control-plane components:** controller-manager and scheduler use their local API server. The etcd leader was also on cp-01 for the whole run (0 leader changes), so cp-01 combined the etcd leader, the busy namespace controller and its share of client traffic. It coped fine (≤ 2 cores for the API server).

### Pod startup latency regression
- **Create:** PodScheduled p99 was 1.0 s, unchanged. PodReadyToStartContainers p99 was 3 s, but **ContainersStarted** p99 was 23 s (avg 6.4 s), against 3.8 s in run 4.
- **Patch:** ContainersStarted p99 was 19.9 s. The patch adds a container, which also needs an image.
- The delay comes after the sandbox is ready, so it is in pulling or starting the container, not in the control plane. The most likely cause is that this is a **new cluster where no worker had the image cached yet**; run 4's nodes had already run the workload. Re-run on this cluster to confirm: if p99 drops back to ~3 s, it was the image pull.

### etcd
- **Disk:** healthy, with fsync p99 of 8 ms and backend commit p99 of 16 ms over the whole run.
- **CPU:** ≤ 0.75 cores per member.
- **Database file:** grew from 154 to **513 MiB**. Compaction brought in-use data back to 138 MiB, but the file doesn't shrink until it is defragmented. That is well below the 2 GiB quota.

## Recommendations
1. **Keep haproxy + keepalived.** This is the change that turned run 4's failure into a clean run.
2. **Re-run once on the same cluster** with the images now cached, to confirm the pod-start regression is only the first image pull. Also record the QPS and BURST values in the results, because `run.sh` does not currently write them to the archive.
3. **To raise create throughput,** increase kube-burner `QPS`/`BURST`. The API servers have headroom: low latency and no queueing.
4. **Defragment etcd between runs** (`etcdctl defrag`, one member at a time) so each run starts from the same database size.
5. **Optional:**
   - Keep the controller-manager and scheduler leaders and the etcd leader on different nodes (`etcdctl move-leader`). This takes the cleanup load off the etcd-leader node.
   - To balance watches better than `leastconn`, consider the API server's `--goaway-chance` (e.g. `0.001`). It makes HTTP/2 clients reconnect from time to time, so their watches spread across the servers.
