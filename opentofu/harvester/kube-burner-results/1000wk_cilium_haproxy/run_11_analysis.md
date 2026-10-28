# Run 11 — api-intensive, 2000 iterations, QPS 300 / burst 400, `goaway-chance=0.001`

Results: `results-api-intensive-20261028T104955Z-BE2rGs`. Benchmark settings are the same as run 10 (`ITERATIONS=2000 QPS=300 BURST=400 PRE_CREATE_NAMESPACES=true`, all metrics `required`, KCM qps 100 / burst 200 / 20 deployment and replicaset workers, `NODE_SAMPLE_COUNT=5`). This is the first run with the new API server series in `apiserver-metrics.tsv` (request duration per resource, terminations, admission and ClusterIP allocation).

Cluster state at start:
- Every API server was restarted shortly before the run, to apply `goaway-chance=0.001`. CPU seconds at start show the restart order: **cp-02, then cp-01, then cp-03** (709 s, 283 s and 51 s).
- etcd: 150 MiB, 90 MiB in use.
- The KCM leader is **cp-02** and the etcd leader is cp-01.
- Long-lived connections are still unevenly spread, but differently from run 10. Goroutines stayed flat for the whole run:
  - **cp-02: 82–93k**;
  - cp-01: 32–34k;
  - cp-03: 3–5k.

## Verdict

**goaway fixed kube-burner's Service timeouts, but it did not rebalance the nodes. The restart order left cp-02 with the KCM leader and most kubelet and Cilium connections, and pods became slower.**

- **Fixed:**
  - **0 Service create timeouts** (904 in run 10).
  - kube-burner's Service creates were spread over all three API servers.
  - 5xx fell to **2** (217 in run 10).
  - No etcd failed proposals and no control-plane restart.
- **Worse:**
  - Job start → all pods Ready: **4m06s** (run 10: 3m22s).
  - Pod Ready p99: **167 s** (run 10: 71 s); average **82 s**. Almost all of it is in `PodReadyToStartContainers`, which is waiting for the sandbox and the CNI.
  - APF rejections: **31,289** (run 10: 9,711). 26.6k of them are on cp-02 in the `kube-system-service-accounts` priority level (Cilium, Traefik and the other kube-system controllers).
- **Why goaway didn't help the nodes:**
  - kubelet and Cilium do not go through HAProxy. They connect through the rke2-agent local load balancer on `127.0.0.1:6443`; Cilium is configured with `k8sServiceHost: localhost`.
  - That load balancer does not balance. It stays on its current server and moves only when a connection to that server fails. When the server sends GOAWAY, the client reconnects to the same server.
  - So goaway helps only clients that go through HAProxy `leastconn`: kube-burner and kubectl.
- **New errors:** 85 read-job `GET deployments` at 10:58:05 failed with `http2: client connection force closed via ClientConn.Close`. This is one client-side HTTP/2 connection closing with 85 requests in flight. It is not a server GOAWAY, which would show as "server sent GOAWAY". All other jobs had 0 errors.

## Comparison

| | run 08 | run 09 | run 10 | **run 11** |
|---|---|---|---|---|
| Change | KCM limits raised | 100 sampled nodes | etcd defrag, 5 sampled nodes | **goaway-chance=0.001, all API servers restarted** |
| etcd DB at start (total / in use) | — | 831 / 823 MiB | 111 / 88 MiB | 150 / 90 MiB |
| Goroutines cp-01 / cp-02 / cp-03 | — | — | 80k / 5k / 30k | **33k / 88k / 4k** |
| KCM leader | cp-03 → restart | cp-02 → restart | cp-01 | **cp-02** |
| kube-burner errors | — | 3,546 | 1,810 | **85** (one connection close) |
| Service create timeouts | 107 | ~595 | 904 | **0** |
| Job start → all pods Ready | 3m23s | ~3.5–4 min | 3m22s | **4m06s** |
| Pod Ready p99 / max | 107 s / 138 s | 168 s / 189 s | 71 s / 110 s | **167 s / 212 s** |
| Initialized p99 | ~1 s | 80 s | 2 s | 1 s |
| PodScheduled p99 | 1.3 s | 2.1 s | 2.3 s | 1.4 s |
| Read / patch | 2m49s / 2m44s | 3m0s / 3m44s | 2m54s / 2m44s | 2m53s / 3m1s |
| remove-deployments / services / configs | 17 / 20 / 50 s | 19 / 22 / 25 s | 11 / 11 / 19 s | 11 / 14 / 32 s |
| APF rejections | 18,359 | 46,668 | 9,711 | **31,289** |
| 5xx | ~770 | ~1,407 | 217 | **2** |
| etcd failed proposals | 302 | 392 | 5 | **0** |
| Control-plane restarts | KCM cp-03 | API server + KCM cp-02 | none | none |
| Peak node CPU cp-01 / cp-02 / cp-03 | — | 37 / 6 / 22 % (coarse) | 98 / 34 / 57 % | **91 / 92 / 20 %** |
| Namespace cleanup | 14m09s | 12m58s | 12m50s | 15m16s |

## Findings

### 1. cp-02 is overloaded: KCM leader plus most node connections

Node CPU during creation:

| Time | cp-01 | cp-02 | cp-03 |
|---|---|---|---|
| 10:51:00 | 91 % | 88 % | 20 % |
| 10:51:43 | 46 % | 81 % | 15 % |
| 10:52:31 | 31 % | 90 % | 14 % |
| 10:53:18 | 30 % | 92 % | 9 % |
| 10:54:21 | 44 % | 74 % | 15 % |
| 10:55:05 | 10 % | 15 % | 5 % |

- The cp-02 API server process used **5.5–7 cores** from 10:51 to 10:54. It served 818–1,097 req/s, with up to 380 requests executing at once.
- cp-03 served about 135 req/s and stayed under 20 % CPU for the whole run.
- RSS grew from 5.1 to 9.5 GiB on cp-02, from 2.5 to 5.8 GiB on cp-01, and from 1.0 to 2.9 GiB on cp-03.
- cp-02 was restarted first, so the agents that failed over during the later restarts of cp-01 and cp-03 landed on cp-02 and stayed there. In run 10 the server restarted last (cp-02) was the idle one. Here cp-03 is.
- etcd slow applies rose by 11.8k on cp-02, 219 on cp-03 and 12 on cp-01. The etcd member on the busiest node is the one falling behind.

### 2. APF rejects Cilium's and the other agents' watches on cp-02

APF rejections by server, priority level and reason:

| Server | Priority level | Reason | Rejections |
|---|---|---|---|
| cp-02 | kube-system-service-accounts | queue-full | 18,882 |
| cp-02 | kube-system-service-accounts | time-out | 7,768 |
| cp-01 | kube-system-service-accounts | queue-full | 4,152 (all at 11:02, during deletion) |
| cp-02 | node-high | time-out | 487 |

- The new `apiserver_request_terminations_total` series show that the rejected requests are mostly **WATCH requests that got a 429**: the clients' watches dropped, and APF refused them when they tried to re-establish them.
- On cp-02:

  | Resource | WATCH 429s |
  |---|---|
  | services | 9,617 |
  | secrets | 4,525 |
  | endpointslices | 1,050 |
  | nodes | 974 |
  | ciliumidentities | 972 |
  | configmaps | 861 |
  | ciliumendpoints | 811 |
  | each Traefik CRD | about 250 |

  There were also 461 `PUT leases` 429s.
- On cp-01: services 2,991, secrets 556 and configmaps 463.
- On the 5 sampled workers, during the slowest windows:

  | Window | CNI `PUT /v1/endpoint` mean | Cilium k8s client latency | Cilium 429s |
  |---|---|---|---|
  | 10:51:45 | 56.6 s | 14.2 s | 12 |
  | 10:52:33 | 50.6 s | 10.2 s | 7 |
  | 10:53:28 | 31.1 s | 7.5 s | 9 |
  | 10:54:24 | 0.2 s | 55 ms | 0 |

  The kubelet `RunPodSandbox` mean reached 70 s at 10:52:33.
- Pods became Ready only after Cilium could reach the API server. That explains the average Ready of 82 s. As in runs 09 and 10, the Cilium datapath is not the bottleneck.

### 3. goaway balanced kube-burner, not the nodes

Service creates in the two creation windows:

| Server, window | Service POSTs | Mean Service POST latency | IPAddress POST | ClusterIP allocation | Admission per step |
|---|---|---|---|---|---|
| cp-03, 10:51:01 | 915 | 6.9 s | 33 ms | 35 ms | 0.1 ms |
| cp-03, 10:51:44 | 63 | 8.5 s | — | — | — |
| cp-01, 10:51:01 | 525 | 8.0 s | 38 ms | 58 ms | 0.2 ms |
| cp-02, 10:51:01 | 166 | 15.2 s | 168 ms | 194 ms | 9.4 ms |
| cp-02, 10:51:44 | 331 | 20.5 s | 24 ms | 38 ms | 9.0 ms |

- kube-burner reaches the API servers through HAProxy (`leastconn`). With goaway its Service creates were spread over all three servers, and none timed out.
- The goroutine counts did not move during the run, so the agents did not rebalance. The rke2-agent load balancer explains this: the k3s `pkg/agent/loadbalancer` code fails over to another server only when a connection attempt to the current one fails. A server that comes back only becomes "preferred"; connections stay where they are.

### 4. ClusterIP allocation and admission don't explain the slow Service POSTs

- A Service POST took **7–20 s** on average, but ClusterIP allocation took 35–194 ms and admission at most 9 ms per step.
- Even cp-03, which used 0.8 cores, averaged 6.9 s per Service create.
- Since Kubernetes 1.35, `DisableAllocatorDualWrite` is locked to on, so the old bitmap allocator and its etcd `GuaranteedUpdate` are not used.
- The new allocator holds a mutex in `MetaAllocator.AllocateNextService`. That serialises the allocation on each API server, but the allocation only takes milliseconds.
- **Correction (run 12):** the time is spent waiting for that mutex. The allocation metric is measured inside the lock, so it doesn't include the wait, and each API server creates at most about 1 / (allocation latency) Services per second. See [run 12](./run_12_analysis.md), finding 1, and kubernetes/kubernetes#142758 (fixed in v1.38).

### 5. Read-job errors

- All 85 errors happened at 10:58:05, on `GET deployments`, with `http2: client connection force closed via ClientConn.Close`.
- The client closed that HTTP/2 connection itself while 85 requests were using it.
- The cause is unclear. It may be client-go closing a connection that it considered broken. The server did not send a 5xx at that time.

## Recommendations

1. **Give Cilium its own API server load balancing** (implemented after this run).
   - `rke2-server-sles.sh` now sets `k8s.apiServerURLs: "https://<VIP>:6443 https://127.0.0.1:6443"`, as in Cilium's [API server high availability](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#kubernetes-api-server-high-availability) docs.
   - With more than one URL, the agent switches to the `kubernetes` Service once it has synced. Cilium's socket load balancer then picks a random API server for every new connection, so goaway spreads Cilium's ~1,000 agents and their watches.
   - This is better than pointing `k8sServiceHost` at the VIP: there is no extra hop, and Cilium does not depend on HAProxy.
2. **Rebalance kubelets after restarting the control plane.**
   - goaway cannot do this. Restart `rke2-agent` on the workers in batches after a control-plane rolling restart.
   - Alternatively, restart the control-plane nodes in an order that leaves the KCM leader on the least-loaded server.
3. **Keep the KCM leader off the busiest API server.** Before a run, check the goroutines per server and the KCM lease holder. If they are on the same server, move the lease by restarting KCM on that server.
4. **Add an APF FlowSchema and priority level for Cilium (and possibly Traefik).** This is still pending from runs 09–10. Watch re-establishment from these agents shares `kube-system-service-accounts` with the rest of kube-system and gets 429s.
5. **Find out where the Service POST time goes.** Answered in [run 12](./run_12_analysis.md): the ClusterIP allocator serializes Service creates on each API server.
6. **Keep defragmenting etcd before each run.**
7. **Investigate the read-job connection close** only if it happens again. It cost 85 requests in one burst, and they did not affect the run.
