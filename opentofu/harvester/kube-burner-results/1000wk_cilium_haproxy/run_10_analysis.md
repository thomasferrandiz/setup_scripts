# Run 10 — api-intensive, 2000 iterations, QPS 300 / burst 400, etcd defragmented, 5 sampled nodes

Results: `results-api-intensive-20261028T094502Z-bPnMz6`. Benchmark settings are the same as run 09 (`ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true`, all metrics `required`, KCM qps 100 / burst 200 / 20 deployment and replicaset workers), except **`NODE_SAMPLE_COUNT=5`** (bench-wk-01, 201, 401, 601, 801).

Cluster state at start:
- etcd was defragmented: **111 MiB, 88 MiB in use** (831 / 823 MiB at the start of run 09).
- No APF change: there is still no Cilium-specific FlowSchema.
- The bench-cp-02 API server has not restarted since run 09. It holds far fewer long-lived connections than the others: **5k goroutines vs 80k on cp-01 and 30k on cp-03**.

## Verdict

**The defrag and the smaller node sample brought the run back to run 08's level, with a cleaner control plane. The remaining bottlenecks are bench-cp-01 CPU, the shared APF queue that slows Cilium, and Service creates timing out.**

- **Fixed compared to run 09:**
  - no `etcdserver: too many requests`;
  - no `connection refused` and no control-plane restart;
  - 5 failed etcd proposals (392 in run 09);
  - KCM stayed on cp-01 for the whole run.
- **Times:**
  - Job start → all pods Ready: **3m22s** (run 08: 3m23s);
  - Pod Ready p99: **71 s** (168 s in run 09, 107 s in run 08); `Initialized` p99: back to 2 s;
  - patch job: 2m44s; read job: 2m54s.
- **Lower load on the control plane:**
  - APF rejections: **9,711** (46,668 in run 09, 18,359 in run 08);
  - 5xx: **217**.
- **Still wrong:**
  - **904 Service creates timed out** (all at 09:46:31–09:47:06, all retried successfully). That is the most since the series began. Only Services fail; ConfigMaps, Secrets and Deployments never time out.
  - **bench-cp-01 node CPU reached 96–98 %** during creation (09:47–09:48), patch (09:54–09:55) and deletion (09:56). cp-01 runs the etcd leader, the KCM leader, and the API server that serves KCM and most watches. cp-02 stayed at 14–24 %.
  - The Cilium CNI was still slow during creation. On the sampled nodes `PUT /v1/endpoint` averaged **32 s** in the 09:48 window, while Cilium's API calls averaged 5.7 s and got 429s. The slow step is still the API server, not the Cilium datapath.
- **Sampling works again:** about one cycle every 40–55 s, with 34 samples per metric. It is still slower than the 30 s target because each cycle runs ~13 sequential scrapes.

## Comparison

| | run 07 | run 08 | run 09 | **run 10** |
|---|---|---|---|---|
| KCM qps / burst / deploy+rs workers | 20 / 30 / 5 | 100 / 200 / 20 | 100 / 200 / 20 | 100 / 200 / 20 |
| Sampled nodes (kubelet + Cilium) | — | — | 100 | **5** |
| etcd DB at start (total / in use) | 478 MiB | — | 831 / 823 MiB | **111 / 88 MiB** |
| kube-burner errors | — | — | 3,546 | 1,810 |
| Service create timeouts | 248 | 107 | ~595 | **904** |
| Services failing with `too many requests` / `connection refused` | 0 / 0 | 0 / 0 | 1,095 / 82 | **0 / 0** |
| Job start → all pods Ready | 8m26s | 3m23s | ~3.5–4 min | **3m22s** |
| Pod Ready p99 / max | 7 s / 11 s | 107 s / 138 s | 168 s / 189 s | **71 s / 110 s** |
| Initialized p99 | — | ~1 s | 80 s | 2 s |
| PodScheduled p99 | — | 1.3 s | 2.1 s | 2.3 s |
| Read / patch | 2m48s / 12m28s | 2m49s / 2m44s | 3m0s / 3m44s | 2m54s / **2m44s** |
| remove-deployments / services / configs | 11 / 15 / 35 s | 17 / 20 / 50 s | 19 / 22 / 25 s | **11 / 11 / 19 s** |
| APF rejections | 4,826 | 18,359 | 46,668 | **9,711** |
| 5xx | 99 | ~770 | ~1,407 | **217** |
| etcd slow applies (Δ, all members) | 5,184 | 8,246 | 10,788 | 11,207 |
| etcd failed proposals | 1 | 302 | 392 | **5** |
| Control-plane restarts | — | KCM cp-03 | API server + KCM cp-02 | **none** |
| Peak node CPU cp-01 / cp-02 / cp-03 | — | — | 37 / 6 / 22 % (coarse) | **98 / 34 / 57 %** |
| Namespace cleanup | 12m49s | 14m09s | 12m58s | 12m50s |

## Findings

### 1. bench-cp-01 is saturated, and the load is unevenly spread

Per-window figures (each window is one sampling cycle of 40–65 s):

| Window end | cp-01 node CPU | cp-02 node CPU | cp-03 node CPU | KCM requests / window | Phase |
|---|---|---|---|---|---|
| 09:46:04 | 79 % | 14 % | 57 % | 5,821 | create |
| 09:47:06 | **96 %** | 21 % | 40 % | 8,998 | create |
| 09:48:00 | **98 %** | 24 % | 36 % | 11,193 | wait for Ready |
| 09:54:02 | **97 %** | 34 % | 40 % | 12,713 | patch |
| 09:54:55 | **96 %** | 24 % | 38 % | 13,694 | patch |
| 09:56:51 | **98 %** | 16 % | 48 % | 8,198 | delete |

- cp-01 runs the **etcd leader** for the whole run and the **KCM leader** for the whole run. Its API server (5.9–6.9 cores during the bursts, 9.2–10.5 GiB RSS) serves the KCM leader's ~200 req/s and most of the watches (80k goroutines).
- cp-02's API server has only **5k goroutines**. It restarted in run 09 at 17:10 (OOM suspected). The 1,000 kubelets and Cilium agents that had been connected to it reconnected through HAProxy to cp-01 and cp-03, and their long-lived HTTP/2 connections stayed there. HAProxy balances in TCP mode (L4), so it cannot move existing connections.
- cp-01 memory was at 72–82 % during the run, and the API server's RSS was 9–10.5 GiB. This is the same situation that preceded the cp-02 restart in run 09.
- KCM is no longer the limit: its rate-limiter wait stayed at 0–43 ms, and the `deployment` and `replicaset` queues drained in 1–2 cycles.

### 2. Service create timeouts

- 904 Service creates (`service-1` in iterations **657–1999**) failed between 09:46:31 and 09:47:06 with `Timeout: request did not complete within requested timeout`. Every retry succeeded. The 2 `already exists` errors show that some of the timed-out creates actually completed on the server.
- kube-burner uses one HTTP/2 connection. In this run it was on **bench-cp-02**: cp-02 is the only member whose POST rate (125/s) matches kube-burner's create rate, and its executing requests are all in the `exempt` flow schema (`system:masters`).
- On cp-02 at 09:46:07 there were **845 requests executing in `exempt`** and 855 mutating requests in flight, with mean POST latency of 0.4 s, then **9.4 s** and 5.1 s in the next windows.
  - By Little's law, 845 in flight at ~125 POST/s means ~7 s per request.
  - etcd writes from cp-02 took only 48–108 ms on average, and cp-02 used just 0.6–1.4 cores.
  - So the requests were waiting inside the API server, not on etcd or the CPU.
- The only step that makes Services different from other creates is ClusterIP allocation. Since Kubernetes 1.33, with ServiceCIDR GA (this cluster runs v1.36.5+rke2r1), each Service create makes an extra `POST /apis/networking.k8s.io/v1/ipaddresses` through the API server's own loopback client. I checked whether that client is rate-limited: the secure loopback config uses `QPS: -1`, so it is not. **The exact wait could not be identified from the sampled series.** `apiserver-metrics.tsv` has no `resource` label, and does not include admission or request-termination metrics.
- Run 09 had fewer timeouts (~595) because many Service creates failed quickly with `too many requests` instead of waiting.

### 3. APF and Cilium

| Member | Priority level / flow schema | Reason | Rejections |
|---|---|---|---|
| cp-01 | workload-high / kube-system-service-accounts | queue-full | 7,599 |
| cp-03 | workload-high / kube-system-service-accounts | queue-full | 1,363 |
| cp-01 | node-high / system-node-high | time-out | 268 |
| cp-01 | system / system-nodes | time-out | 257 |
| cp-01 | workload-high / kube-system-service-accounts | time-out | 221 |
| cp-03 | workload-high / kube-system-service-accounts | time-out | 3 |

- Rejections happen in two bursts: 09:46–09:48 (creation) and 09:55–09:57 (patch and deletion). None happened on cp-02, because of the connection imbalance described in finding 1.
- On the 5 sampled workers:

| Window end | Pods sandboxed | `RunPodSandbox` mean | Cilium `PUT /v1/endpoint` mean | Cilium k8s calls (429) | Cilium k8s latency |
|---|---|---|---|---|---|
| 09:46:15 | 2 | 4.1 s | 2.7 s | 0 | 1.0 s |
| 09:47:11 | 1 | 1.4 s | 0.15 s | 6 | 26 ms |
| 09:48:08 | 5 | **33.6 s** | **32.3 s** | 3 | **5.7 s** |
| 09:53:14–09:54:05 (patch) | 9 | 0.8–0.9 s | 0.12–0.15 s | 0 | 91–155 ms |

  `RunPodSandbox` time is almost entirely the CNI `PUT /v1/endpoint`. Within that call, Cilium's endpoint regeneration takes 10–140 ms, and the rest is waiting for the API server.
- Five nodes created only 8 pods during the creation phase. That is enough to see the pattern but not to give precise percentiles.
- The endpoint-create limiter's `wait_duration_seconds{value="max"}` gauge is 60 s in every sample, including idle ones. It is a lifetime maximum and should be ignored. The run 09 analysis has been corrected.

### 4. etcd

- **Defragmenting before the run worked.** etcd went from 111 MiB to 618 MiB during the run, with 171 MiB in use at the end. There were no `too many requests` errors, 5 failed proposals, and at most 40 pending proposals (cp-03).
- 11,207 slow applies, mostly during creation (09:46–09:48) and patch/delete (09:54–09:56). This is in line with runs 08 and 09: it is the cost of the write load, not of the DB size.

## Recommendations

1. **Spread the load on the control plane.**
   - Add `goaway-chance=0.001` to `kube-apiserver-arg`. The API server then randomly closes about 1 in 1,000 HTTP/2 requests with GOAWAY, which makes clients reconnect through HAProxy over time. This rebalances long-lived kubelet and Cilium connections after a restart, which L4 HAProxy cannot do.
   - Keep the etcd leader and the KCM leader on different nodes, for example with `etcdctl move-leader` before the run.
   - If cp-01 still saturates, increase the control-plane VMs (8 → 16 vCPU and more memory). The API server uses 9–10.5 GiB RSS on nodes that also run etcd and KCM.
2. **Find out where Service creates wait.** These would identify the blocking step:
   - check the kube-apiserver logs on the node serving kube-burner for `Trace[...] "Create" url:/api/v1/namespaces/*/services`. The API server logs a step-by-step trace for requests slower than 500 ms;
   - add `apiserver_request_terminations_total`, `apiserver_admission_step_admission_duration_seconds` and `apiserver_request_duration_seconds` for `resource=services|ipaddresses` to the API server sampling in `run.sh`.
3. **Give Cilium its own APF priority level.** Still pending since run 08; 9,186 `kube-system-service-accounts` rejections and 32 s CNI calls in this run.
4. **Keep defragmenting etcd before each run.** It removed the run 09 etcd failures.
5. **Run the node scrapes in parallel** (bounded concurrency) so `NODE_SAMPLE_COUNT=5` fits within the 30 s interval. The current 40–65 s cycles are usable but blur the creation phase.
6. **Optional:**
   - lower kube-burner to QPS 200 / burst 300 to check whether the Service timeouts and cp-01 saturation scale with load;
   - set KCM `leader-elect-lease-duration=60s` / `renew-deadline=40s` (not needed this run: no restarts).
