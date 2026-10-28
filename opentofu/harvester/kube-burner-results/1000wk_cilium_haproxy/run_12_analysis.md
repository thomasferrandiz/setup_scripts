# Run 12 — api-intensive, 2000 iterations, QPS 300 / burst 400, Cilium `k8s.apiServerURLs`

Results: `results-api-intensive-20261028T145428Z-vykw0j`. Benchmark settings are the same as run 11 (`ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true`, all metrics `required`, KCM qps 100 / burst 200 / 20 deployment and replicaset workers, `NODE_SAMPLE_COUNT=5`, `goaway-chance=0.001`).

Cluster state at start:
- **The Cilium agents were restarted after run 11.** Their `cilium_k8s_client_api_calls_total` counters dropped from about 3,100–3,250 at the end of run 11 to 720–975. This fits the rollout of `k8s.apiServerURLs` ([run 11](./run_11_analysis.md), recommendation 1). The runner keeps only the `method` and `return_code` labels, so the results can't confirm that the agents switched to the `kubernetes` Service address.
- **bench-cp-02 was restarted a few minutes before the run.**
  - Its API server had used only 92 CPU seconds at 14:55:30.
  - Its etcd member is now the leader, and its database is 161 MiB, against 701 MiB on cp-01 and cp-03. Only cp-02 looks defragmented.
- **Goroutines per API server** at 14:55 were 68k on cp-01, 46k on cp-03 and **3.4k on cp-02**. The cp-02 restart happened after the Cilium rollout, so cp-02's connections moved to the other two servers and did not come back.
- The KCM leader is **cp-03** for the whole run, and the etcd leader is cp-02.

## Verdict

**The best run so far: 0 errors, 0 Service timeouts and 0 5xx, all pods Ready in 3m17s, and pods Ready about 2.5 times faster on average than in run 11. The load is still uneven, because cp-02 was restarted after the Cilium rollout and goaway refills it very slowly. The Service create latency is explained: Kubernetes 1.36 allocates ClusterIPs one at a time on each API server.**

- **Better than run 11:**
  - kube-burner errors: **0** (85 in run 11, 1,810 in run 10).
  - Service create timeouts and 5xx: **0 / 0**.
  - Job start → all pods Ready: **3m17s** (4m06s in run 11, 3m22s in run 10).
  - Pod Ready average: **32 s** (82 s in run 11); p99 **115 s** (167 s).
  - APF rejections: **18,851** (31,289 in run 11).
  - On the sampled workers, the CNI `PUT /v1/endpoint` took **3.9 s** on average (31–57 s in run 11), and sandbox creation 5.6 s.
  - Read 2m52s, patch 2m42s, and no etcd failed proposals.
- **Still uneven:** cp-01 and cp-03 reached 90–99 % node CPU, while cp-02 stayed at 6–26 %. In 25 minutes, goaway moved only about 2.4k goroutines to cp-02.
- **Service POSTs are serialized:** the 1.36 ClusterIP allocator holds a lock for each allocation. Even on cp-02, which was nearly idle, a Service create averaged **3.8 s**.

## Comparison

| | run 09 | run 10 | run 11 | **run 12** |
|---|---|---|---|---|
| Change | 100 sampled nodes | etcd defrag, 5 sampled nodes | goaway-chance=0.001 | **Cilium `k8s.apiServerURLs`; cp-02 restarted just before** |
| etcd DB at start (total / in use) | 831 / 823 MiB | 111 / 88 MiB | 150 / 90 MiB | **701 MiB on cp-01 and cp-03, 161 MiB on cp-02 / 168 MiB in use** |
| Goroutines cp-01 / cp-02 / cp-03 | — | 80k / 5k / 30k | 33k / 88k / 4k | **68k / 3.4k / 46k** |
| KCM leader | cp-02 → restart | cp-01 | cp-02 | cp-03 |
| kube-burner errors | 3,546 | 1,810 | 85 | **0** |
| Service create timeouts | ~595 | 904 | 0 | **0** |
| Job start → all pods Ready | ~3.5–4 min | 3m22s | 4m06s | **3m17s** |
| Pod Ready p99 / max / avg | 168 / 189 s / — | 71 / 110 s / — | 167 / 212 / 82 s | **115 / 152 / 32 s** |
| Initialized p99 | 80 s | 2 s | 1 s | 5 s |
| PodScheduled p99 | 2.1 s | 2.3 s | 1.4 s | 1 s |
| Read / patch | 3m0s / 3m44s | 2m54s / 2m44s | 2m53s / 3m1s | 2m52s / 2m42s |
| remove-deployments / services / configs | 19 / 22 / 25 s | 11 / 11 / 19 s | 11 / 14 / 32 s | 11 / 17 / 19 s |
| APF rejections | 46,668 | 9,711 | 31,289 | **18,851** |
| 5xx | ~1,407 | 217 | 2 | **0** |
| etcd failed proposals | 392 | 5 | 0 | 0 |
| Control-plane restarts during the run | API server + KCM cp-02 | none | none | none |
| Peak node CPU cp-01 / cp-02 / cp-03 | 37 / 6 / 22 % (coarse) | 98 / 34 / 57 % | 91 / 92 / 20 % | **99 / 26 / 91 %** |
| Namespace cleanup | 12m58s | 12m50s | 15m16s | 13m19s |

## Findings

### 1. Service creates are serialized by the ClusterIP allocator

Every Service create went to cp-02 or cp-03. kube-burner reaches the API servers through HAProxy `leastconn`, which preferred cp-02, the server with the fewest connections.

| Server, window | Service POSTs | Mean POST latency | ClusterIP allocation | API server CPU |
|---|---|---|---|---|
| cp-02, 14:56:22 | 1,565 | **3.8 s** | 19 ms | 1.0 core |
| cp-03, 14:56:23 | 435 | 15.6 s | 84 ms | 5.7 cores |
| run 11 cp-03, 10:51:01 | 915 | 6.9 s | 35 ms | 0.8 core |
| run 11 cp-02, 10:51:44 | 331 | 20.5 s | 38 ms | 5.5–7 cores |

- In Kubernetes 1.36, `MetaAllocator.AllocateNextService` (`pkg/registry/core/service/ipallocator/cidrallocator.go`) holds an exclusive `sync.Mutex` while it allocates an IP. The allocation includes the loopback `POST ipaddresses`, which writes to etcd.
- The `kube_apiserver_clusterip_allocator_allocation_duration_seconds` metric only measures the time inside the lock. The time spent waiting for the lock is not counted.
- So each API server can create at most about 1 / (allocation latency) Services per second: about 50 per second at 19 ms, about 12 per second at 84 ms. When kube-burner creates Services faster than that, they queue, and the queue is the multi-second latency.
- That is why even the idle cp-02 averaged 3.8 s, and why the busy server is much worse: higher CPU makes each allocation slower, which lowers the rate further.
- Upstream fixed this in kubernetes/kubernetes#142758, which uses an `RWMutex` and makes allocations concurrent. It reports 18× the Service create throughput (220 → 3,948 Services/s in the integration test). It is merged for **v1.38** and has not been backported; it is labelled `kind/cleanup`.

### 2. cp-02 was left almost idle

Node CPU (cp-01 / cp-02 / cp-03):

| Time | cp-01 | cp-02 | cp-03 | |
|---|---|---|---|---|
| 14:56:11 | 80 % | 16 % | 77 % | creation |
| 14:58:02 | 98 % | 22 % | 90 % | creation |
| 15:03:25 | 91 % | 26 % | 76 % | patch |
| 15:04:22 | 87 % | 23 % | 88 % | patch |
| 15:06:13 | 99 % | 18 % | 79 % | deletion |
| 15:07:04 | 93 % | 8 % | 91 % | deletion |

- The API servers on cp-01 and cp-03 used 4–7 cores during creation and patch, while cp-02 used 0.2–1.1 cores.
- Apart from kube-burner's creates, cp-02 served 3–200 requests/s, against 400–880 on cp-01.
- From 14:55 to 15:19, cp-02's goroutines grew from 3.4k to only 5.8k. GOAWAY is sent with a probability of 0.001 per request, and an idle agent makes only a few requests per minute, so each agent gets a GOAWAY only every few hours. goaway is a slow correction, not a way to rebalance after a restart.
- Cilium now uses the Service address, so `kubectl -n kube-system rollout restart daemonset/cilium` spreads the agents again at random. Kubelets still need `rke2-agent` restarts.

### 3. APF: fewer rejections, all on the two busy servers

| Server | Priority level (flow schema) | Reason | Rejections |
|---|---|---|---|
| cp-01 | workload-high (kube-system-service-accounts) | queue-full | 9,347 |
| cp-01 | system (system-nodes) | time-out | 1,008 |
| cp-01 | workload-high (kube-system-service-accounts) | time-out | 818 |
| cp-01 | system (system-nodes) | queue-full | 337 |
| cp-03 | workload-high (kube-system-service-accounts) | queue-full | 7,200 |
| cp-02 | — | — | 0 |

- As in run 11, `apiserver_request_terminations_total` shows that most rejected requests are WATCH re-establishments: services, endpointslices, secrets, nodes, configmaps and ciliumidentities.
- cp-03 also rejected 262 `POST ciliumidentities` with 429. Those delay the identity of new pods.
- The kubelets' `system` level now gets time-outs on cp-01: 1,345 rejections in total.

### 4. Pods and Cilium

- On the 5 sampled workers, during creation, the CNI took 3.9 s and the Cilium API calls 1.4 s on average, with 16 responses of 429.
- The overall pod latency, an average of 32 s and a p99 of 115 s, is still longer than that. Pods on nodes whose agents are on cp-01 or cp-03 were probably slower. With 5 sampled nodes the run can't show the spread.
- `Initialized` p99 rose to 5 s (max 27 s). There were also 10 kube-burner warnings `failed to get started of pod ... time from event`; these only affect the measurement.

### 5. etcd

- No failed proposals and no leader change during the run.
- Slow applies rose by 2.6k on cp-01, 1.0k on cp-03 and 5 on cp-02, the leader.
- cp-01 and cp-03 started at 701 MiB, which is not defragmented, while cp-02 started at 161 MiB. In-use space is 168–175 MiB on every member.

## Recommendations

1. **After restarting a control-plane node, rebalance before running.**
   - Run `kubectl -n kube-system rollout restart daemonset/cilium` (Cilium now picks a random API server).
   - Then restart `rke2-agent` on the workers in batches for the kubelets.
   - Check that `go_goroutines` is roughly even across the API servers before starting kube-burner.
   - Restart control-plane nodes, for example for a defrag, **before** these restarts, not after.
   - **Implemented:** `kube-burner/rebalance.sh` does all three steps from the jump host.
2. **Record the API server host for Cilium's client calls.** Add the `host` label to `cilium_k8s_client_api_calls_total` in `run.sh`. This shows whether the agents use the Service address (`10.43.0.1:443`) or the bootstrap URLs.
   - **Implemented:** `run.sh` keeps `host` in `cilium-metrics.tsv`.
3. **Expect Service creates to be capped on 1.36.**
   - Spreading Service creates across all three API servers and keeping their CPU low is the only mitigation.
   - The fix (kubernetes/kubernetes#142758) arrives in v1.38. Alternatively, ask for a backport, since the PR states the performance gain.
   - Until then, the Service create latency mostly measures the allocator queue, not etcd or API server CPU.
4. **Defragment all etcd members before each run,** not just one.
5. **Add an APF FlowSchema and priority level for Cilium (and Traefik).** The `workload-high` queue still rejects their watches on the busy servers.
   - **Implemented for Cilium:** `rke2-server-sles.sh` installs `cilium-apf.yaml` (priority level `cilium`, FlowSchema at precedence 850, flows by user). Traefik still uses `kube-system-service-accounts`.
6. **Sample more nodes, or change the sampled set between runs,** to see how pod latency varies with the API server each node uses. 5 nodes keep the sampling cycle at about 45 s.
