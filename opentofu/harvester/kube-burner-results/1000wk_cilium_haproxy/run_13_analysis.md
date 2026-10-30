# Run 13 — api-intensive, 2000 iterations, QPS 300 / burst 400, Cilium APF priority level

Results: `results-api-intensive-20261028T172036Z-VrakZR`. Benchmark settings are the same as run 12 (`ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true`, all metrics `required`, KCM qps 100 / burst 200 / 20 deployment and replicaset workers, `NODE_SAMPLE_COUNT=5`, `goaway-chance=0.001`). It is the first run with the `cilium` APF priority level and FlowSchema, and with the `host` label on `cilium_k8s_client_api_calls_total`.

Cluster state at start:
- **cp-01 and cp-02 had been restarted shortly before the run.** At 17:20:54 their API servers had used 411 and 80 CPU seconds, against 14,789 on cp-03.
- **The load was not rebalanced after those restarts.** Goroutines per API server were **31k on cp-01, 6k on cp-02 and 78k on cp-03**. cp-03's API server used 7.1 GiB RSS, and the cp-03 node 11.4 GiB (72 %) of memory.
- **etcd was not defragmented:** all three members were at **960 MiB, with 175 MiB in use**. etcd leader: cp-02. No leader change or failed proposal during the run.
- The KCM leader is **cp-03**, the most loaded server, for the whole run.

## Verdict

**Pods became Ready about 3 times faster than in run 12, and the `cilium` priority level rejected nothing. But the cluster started unbalanced, so cp-03 carried almost all the agent and controller traffic and the job took longer to finish. 66 read errors came from one dropped kube-burner connection, as in run 11.**

- **Better than run 12:**
  - Pod Ready p99 **37 s** (115 s in run 12), max **86 s** (152 s), average **10 s** (32 s).
  - APF rejections **9,156** (18,851). **0** in the new `cilium` level, which queued up to 384 requests and borrowed up to 164 seats on cp-01.
  - Service creates went to cp-02 and cp-01, and averaged **2.0 s** on cp-02 (3.8 s in run 12).
  - Service timeouts 0; only 16 server-side 5xx.
- **Worse than run 12:**
  - Job start → all pods Ready: **4m03s** (3m17s). The time was lost before pods existed. The deployment controller (KCM on cp-03) waited on a saturated cp-03 for the first two minutes.
  - cp-03 reached 100 % node CPU, while cp-01 peaked at 58 % and cp-02 at 28 %.
  - Patch 3m10s (2m42s); remove-* 14 / 25 / 35 s (11 / 17 / 19 s); cleanup 14m14s (13m19s).
  - kube-burner errors: **66** (0). All are read-job GETs, lost when one HTTP/2 connection dropped at 17:26:27.
- **The new `host` label can't show where Cilium's traffic goes.** client-go labels each call with the URL its client was created with, not the address the request is actually sent to (Finding 4).

## Comparison

| | run 10 | run 11 | run 12 | **run 13** |
|---|---|---|---|---|
| Change | etcd defrag, 5 sampled nodes | goaway-chance=0.001 | Cilium `k8s.apiServerURLs` | **Cilium APF level; cp-01 and cp-02 restarted, no rebalance** |
| etcd DB at start (total / in use) | 111 / 88 MiB | 150 / 90 MiB | 701 (cp-02: 161) / 168 MiB | **960 / 175 MiB** |
| Goroutines cp-01 / cp-02 / cp-03 | 80k / 5k / 30k | 33k / 88k / 4k | 68k / 3.4k / 46k | **31k / 6k / 78k** |
| KCM leader | cp-01 | cp-02 | cp-03 | cp-03 |
| kube-burner errors | 1,810 | 85 (read, connection closed) | 0 | **66 (read, connection dropped)** |
| Service create timeouts | 904 | 0 | 0 | 0 |
| Job start → all pods Ready | 3m22s | 4m06s | 3m17s | **4m03s** |
| Pod Ready p99 / max / avg | 71 / 110 s / — | 167 / 212 / 82 s | 115 / 152 / 32 s | **37 / 86 / 10 s** |
| Initialized p99 | 2 s | 1 s | 5 s | 5 s |
| PodScheduled p99 | 2.3 s | 1.4 s | 1 s | 4 s |
| Read / patch | 2m54s / 2m44s | 2m53s / 3m1s | 2m52s / 2m42s | 2m52s / 3m10s |
| remove-deployments / services / configs | 11 / 11 / 19 s | 11 / 14 / 32 s | 11 / 17 / 19 s | 14 / 25 / 35 s |
| APF rejections | 9,711 | 31,289 | 18,851 | **9,156** (0 for Cilium) |
| 5xx | 217 | 2 | 0 | 16 |
| etcd failed proposals | 5 | 0 | 0 | 0 |
| Peak node CPU cp-01 / cp-02 / cp-03 | 98 / 34 / 57 % | 91 / 92 / 20 % | 99 / 26 / 91 % | **58 / 28 / 100 %** |
| Namespace cleanup | 12m50s | 15m16s | 13m19s | 14m14s |

## Findings

### 1. cp-03 carried the cluster, and the deployment controller waited on it

kube-burner itself was spread out: its creates went mostly to cp-02, through HAProxy `leastconn`. Everything else was on cp-03: the kubelets and other clients that failed over when cp-01 and cp-02 restarted, and the KCM leader, which talks to its local API server.

cp-03 during creation:

| Time | Node CPU | API server mean latency (POST / PUT / LIST) | KCM POST / PUT mean | KCM requests | deployment queue | replicaset queue |
|---|---|---|---|---|---|---|
| 17:21:37 | 75 % | 473 / 658 / 1,557 ms | 564 / 1,800 ms | 40/s | 1,988 | 68 |
| 17:22:30 | 100 % | 1,422 / 1,001 / 1,213 ms | 1,191 / 945 ms | 52/s | 1,994 | 314 |
| 17:23:19 | 92 % | 216 / 152 / 156 ms | 292 / 217 ms | 210/s | 1,986 | 1,696 |
| 17:24:11 | 91 % | 183 / 81 / 108 ms | 339 / 150 ms | 177/s | 0 | 1,555 |
| 17:25:02 | 60 % | 75 / 56 / 60 ms | 112 / 125 ms | 151/s | 0 | 0 |

- kube-burner created all 2,000 iterations by 17:21:41, but the deployment controller's queue stayed at about 1,990 until 17:23:19. KCM requests took 0.5–1.8 s each, with almost no client-side throttling (rate-limiter wait under 30 ms). With 20 workers, that caps it at 11–40 requests/s.
- In the same window, cp-03 served 484 WATCH/s and answered 6.4k requests with 429 (Finding 3). Its latency fell as soon as that storm ended, and KCM's throughput rose fivefold.
- Pods were Ready 10 s after creation on average, so the 4m03s total is mostly time before the pods existed. Pod Ready latency is measured from each pod's creation and doesn't include that time.
- During the patch job (17:29:57–17:31:27), cp-03 again reached 96–98 % CPU, while cp-01 was at 42–58 % and cp-02 at 23–24 %.
- Memory: cp-03's API server reached 9.6 GiB RSS, and the cp-03 node 12.1 GiB (about 75 %). An API server holding about half of all agent connections also holds most of the watch memory.

### 2. Service creates were faster on the lightly loaded servers

| Server | Service POSTs | Mean POST latency | ClusterIP allocation |
|---|---|---|---|
| cp-02 | 1,840 | **2.0 s** | 15 ms |
| cp-01 | 160 | 1.2 s | 53 ms |
| cp-03 | 0 | — | — |
| run 12 cp-02 | 1,565 | 3.8 s | 19 ms |
| run 12 cp-03 | 435 | 15.6 s | 84 ms |

- This is the 1.36 allocator limit from [run 12](./run_12_analysis.md) (Finding 1): one ClusterIP allocation at a time on each API server. It is lower here because the server doing the allocations was nearly idle.

### 3. APF: Cilium is isolated, but the remaining kube-system flow still saturates

| Server | Priority level (flow schema) | Reason | Rejections |
|---|---|---|---|
| cp-03 | workload-high (kube-system-service-accounts) | queue-full | 8,600 |
| cp-03 | system (system-nodes) | time-out | 216 |
| cp-01 | workload-high (kube-system-service-accounts) | queue-full | 179 |
| cp-03 | node-high (system-node-high) | time-out | 132 |
| cp-03 | workload-high (kube-system-service-accounts) | time-out | 29 |
| all | cilium | — | **0** |

- The `cilium` level absorbed the agents' bursts: up to 384 requests queued on cp-03 and 164 executing on cp-01, without a single rejection. The sampled agents got no 429s (16 in run 12).
- The rejections came in two bursts on cp-03: 7.1k at 17:21–17:23 (creation) and 1.9k at 17:33–17:34 (the remove jobs).
- The rejected requests are WATCH re-establishments (`apiserver_request_terminations_total`):
  - secrets 3,689, services 2,396, nodes 1,139, configmaps 1,002;
  - about 40–50 on each Traefik CRD and on ingresses and ingressclasses;
  - and 117 `PUT leases`.
- `kube-system-service-accounts` uses `ByNamespace`, so every remaining kube-system ServiceAccount is still one flow. When one client re-establishes many watches, everything else in kube-system is rejected too. These metrics can't tell which ServiceAccount started the storm.
- Watch re-establishment at the moment kube-burner creates 2,000 secrets, configmaps and Services fits watchers being closed because they couldn't keep up. The runner doesn't record `apiserver_terminated_watchers_total`, so this can't be confirmed yet.

### 4. The Cilium `host` label shows the bootstrap URL, not the Service

| Sampled agent | Calls labelled bootstrap URL (start → end) | Calls labelled `10.43.0.1:443` |
|---|---|---|
| wk-01 | VIP 75 → 157 | 7 → 7 |
| wk-201 | VIP 106 → 195 | 8 → 8 |
| wk-401 | 127.0.0.1 79 → 174 | 7 → 7 |
| wk-601 | 127.0.0.1 98 → 193 | 9 → 9 |
| wk-801 | 127.0.0.1 71 → 165 | 10 → 10 |

- client-go sets the label from the REST client's base URL (`sanitize()` uses `req.c.base.Host` in `rest/request.go`), which is fixed when the clientset is created.
- Cilium builds its main clientset with the bootstrap URL it picked at random. After the switch, its rotating round-tripper (`pkg/k8s/client/rest_config_provider.go`) rewrites `req.URL.Host` to the Service address under client-go. So the label keeps the bootstrap URL even when the request goes to `10.43.0.1:443`.
- The 7–10 calls labelled `10.43.0.1:443` on every agent probably come from `checkConnToService`, which builds its own clientset on the Service address before switching. That suggests every sampled agent switched, but it doesn't prove where the later calls went.
- The label is still useful to see which bootstrap URL each agent picked. In this sample, 2 agents picked the VIP and 3 picked `127.0.0.1:6443`.

### 5. kube-burner lost one HTTP/2 connection at the start of the read job

- At 17:26:27, 2 s into the read job, 60 concurrent `GET deployments` failed with `unexpected EOF` while reading the response body. At 17:27:11, 6 `GET pods` failed with `http2: client connection force closed via ClientConn.Close`.
- 44 s between the two matches client-go's HTTP/2 health check: 30 s without frames, then a 15 s ping timeout. So one connection was closed by the remote side, and another went silent until the client gave up on it.
- No API server restarted (CPU counters keep rising), and no server returned 5xx at that time. HAProxy's client and server timeouts are 1 h.
- Run 11 had the same failure at the start of its read job (85 GETs at 10:58:05, "force closed"). Run 12 had none.
- These errors are only in the read job; the created objects are not affected. With the current metrics, the cause can't be identified. Possible sources are HAProxy, a Keepalived VIP move, or a GOAWAY interacting with in-flight streams.

### 6. Pods, CNI and etcd

- On the 5 sampled workers, only 4 pods were created in this run. On those pods, sandbox creation took 1.4 s and the CNI `PUT /v1/endpoint` 0.18 s (5.6 s and 3.9 s in run 12).
- etcd: no leader change, no failed proposal. Slow applies rose by 8.3k on cp-03, 79 on cp-01 and 41 on cp-02 (the leader). In-use space peaked at 671 MiB during creation, so the undefragmented 960 MiB file did not grow.

## Recommendations

1. **Before each run: defragment, then rebalance, then check.** Run 13 started with 31k / 6k / 78k goroutines and an undefragmented etcd.
   - Restarting a control-plane node is not a step. It means: if any kube-apiserver was restarted since the last rebalance, for any reason, do that first, then rebalance.
     - A reboot and `rke2-killall.sh` both restart it.
     - `systemctl restart rke2-server` restarts it only if the static pod manifest changed.
     - To tell, compare the API servers' `process_cpu_seconds_total` or pod start times.
   - Run `./defrag-etcd.sh`, then `./rebalance.sh`.
   - Start kube-burner only when the "After:" goroutines are within about a factor of 2 of each other. Run `rebalance.sh` again (`CILIUM=no` is enough for kubelets) if one server is still far lower.
   - The KCM leader always uses its local API server, so its server carries extra load. Check the goroutines are even, rather than relying on the rebalance alone.
2. **Split the remaining kube-system flow by ServiceAccount.**
   - Add a FlowSchema at precedence 890 for all ServiceAccounts in kube-system, with `distinguisherMethod: ByUser`, pointing to `workload-high`.
   - Then a storm from one controller only fills that controller's queues, and Traefik and the others keep theirs.
   - This replaces "and Traefik" from run 12 recommendation 5.
3. **Record which watchers the API server closes.** Add `apiserver_terminated_watchers_total` (by resource) to the API server metrics in `run.sh`. If it rises in the creation and remove bursts, slow watchers being closed is the cause of the 429 storms.
4. **Find out what drops kube-burner's connection** (runs 11 and 13). Right after a run with read errors, collect from both `bench-lb-01` and `bench-lb-02`:
   - `sudo journalctl -u haproxy --since ... --until ...`. With `option tcplog`, the termination flags show which side closed the connection.
   - `sudo journalctl -u keepalived` for VRRP state changes.
   - Also note which API server the closed connection went to.
5. **Verify Cilium's API server address on the node, not with the metric.**
   - On a worker, `sudo ss -tnp | grep cilium-agent` shows the real destination. With the Service, Cilium's socket load balancer connects straight to an API server (`192.168.x.x:6443`); without it, the destination is `127.0.0.1:6443` or the VIP.
   - Or look for `Updated kubeapi server url host` in an agent's log.
   - The `kube-burner/README.md` text that said the label would show the switch has been corrected.
6. **Watch cp-03's memory.** Its API server reached 9.6 GiB RSS and the node 75 % of memory while holding most connections. Rebalancing (recommendation 1) should bring this down. If it doesn't, the control-plane VMs need more memory before larger runs.
