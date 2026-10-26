# RKE2 kube-burner benchmarks

Two workloads share the same runner (`run.sh`), selected with `WORKLOAD`:

| `WORKLOAD` | Stresses | Default iterations (max) | Default QPS | Default hold |
|---|---|---|---|---|
| `kubelet-density-heavy` (default) | Scheduling, kubelets, container startup, CPU/memory | 10 (1000) | 10 | 10m |
| `api-intensive` | kube-apiserver and etcd | 100 (5000) | 50 | 1m |

Common settings: `QPS` and `BURST` (1–1000; `BURST` defaults to `QPS`),
`TIMEOUT` (kube-burner overall timeout, default `2h`), `SAMPLE_INTERVAL`
(seconds, default 30) and `ETCD_METRICS` (`auto`, `required` or `off`; see
[etcd metrics](#etcd-metrics)).

## kubelet-density-heavy

Based on the upstream [kubelet-density-heavy workload](https://github.com/kube-burner/kube-burner/tree/main/examples/workloads/kubelet-density-heavy).
Each iteration creates one PostgreSQL Deployment, one perfapp Deployment and a
Service connecting them. This stresses API writes, scheduling, image pulls,
container startup, DNS and database connectivity. It is a density/startup
benchmark, **not a sustained CPU saturation or memory exhaustion generator**.

### Run

Use kube-burner **v2.8.6**, kubectl, jq, and a kubeconfig with admin access to the
**downstream RKE2 cluster**. Do not use Harvester's `../local.yaml`.
The kubeconfig endpoint must be reachable from the machine running the benchmark
(for example, run it on the jump host with a kubeconfig pointing at the RKE2 VIP).
The Metrics API (`metrics.k8s.io`, normally provided by RKE2's metrics-server)
must be available and already reporting node usage. The runner fails before
starting the workload if node metrics or API server metrics cannot be queried.

```bash
export KUBECONFIG=/absolute/path/to/rke2.yaml
cd opentofu/harvester/kube-burner
kubectl top nodes

# Smoke test: 10 iterations = 20 pods, followed by a 10-minute hold.
bash run.sh

# Explicit scale-up: 1000 iterations = 2000 pods and 1000 Services.
ITERATIONS=1000 HOLD_DURATION=20m SAMPLE_INTERVAL=30 bash run.sh
```

Start small and increase deliberately. The runner caps iterations at 1000, uses
QPS/burst 10 by default, and kube-burner has a 2-hour overall timeout by default. Choose a hold shorter
than that timeout, allowing time for creation, readiness and cleanup. The hold
starts after readiness (maximum readiness wait 30 minutes). Do not run multiple
copies concurrently: the workload uses a fixed namespace prefix.

Control-plane nodes are excluded by affinity; no `CriticalAddonsOnly`
toleration is added to application pods. Unlike upstream's worker selector,
this works without a `node-role.kubernetes.io/worker` label on RKE2 agents.
Soft hostname spreading encourages distribution but does not guarantee one pair
per worker. Each pair requests 200m CPU and 384Mi RAM, with combined limits of
1 CPU and 768Mi RAM. At 1000 pairs this is 200 CPU / 375Gi requested, and up to
1000 CPU / 750Gi limited, in addition to system workloads.

PostgreSQL uses `postgres:16-bookworm` instead of upstream's obsolete PostgreSQL
10 image. Its data is ephemeral (`emptyDir`, 2Gi cap per instance). Database
credentials are disposable benchmark credentials, not production credentials.
The perfapp image is the upstream `quay.io/cloud-bulldozer/perfapp:latest`.
Workers need registry access. For repeatable comparisons, pin both images to
tested digests before running; first runs include image download overhead.

## api-intensive

Based on the upstream [api-intensive workload](https://github.com/kube-burner/kube-burner/tree/main/examples/workloads/api-intensive),
plus a read phase. The prerequisites are the same as for kubelet-density-heavy
(see Run above). The workload generates many API requests while keeping node load low:

1. **Create**: each iteration creates a namespace with a ConfigMap, a Secret, a
   Service, and a one-replica `pause` Deployment that mounts them. The job waits
   for readiness, then holds for `HOLD_DURATION`.
2. **Read**: `READ_ITERATIONS` times (default 5, max 100), cluster-wide LISTs of
   each kind (ConfigMaps, Secrets, Services, Deployments and Pods), then a GET of
   every object.
3. **Patch**: `PATCH_ITERATIONS` times (default 3, max 100), every Deployment is
   patched with a JSON patch, a server-side apply (adds a container, causing a
   rollout), and a strategic-merge patch.
4. **Delete**: Deployments, then Services, then ConfigMaps and Secrets, waiting
   for each deletion. Garbage collection removes the ReplicaSets and pods in the
   background; there is no separate pod-deletion step, because it would race
   the ReplicaSets, which recreate pods. Global GC then deletes the namespaces.

```bash
export KUBECONFIG=/absolute/path/to/rke2.yaml
cd opentofu/harvester/kube-burner

# Smoke test: 100 namespaces, 500 objects.
WORKLOAD=api-intensive bash run.sh

# Heavier run: 1000 namespaces, higher client rate.
WORKLOAD=api-intensive ITERATIONS=1000 QPS=100 BURST=200 bash run.sh
```

The total request count scales roughly with
`ITERATIONS × (5 + 5 × READ_ITERATIONS + 3 × PATCH_ITERATIONS + deletes)`, and
kube-burner throttles it to `QPS`. On the 1000-worker cluster, 1000 iterations
at QPS 100 took about 26 minutes, including namespace cleanup and excluding image
pre-loading. Rollouts after the patch and garbage collection account for much of it. Raise `QPS`/`BURST` to increase the request rate; at 5000 iterations,
also raise `TIMEOUT`. Each pod requests 10m CPU / 16Mi (limits 50m / 32Mi), so
1000 iterations requests about 10 CPU / 16Gi across the workers. Pods avoid
control-plane nodes, which have no toleration. Workers must be able to pull
`registry.k8s.io/pause:3.10`. Image pre-loading is disabled: kube-burner's
pre-load DaemonSet takes about 9 minutes on 1000 nodes and adds unrelated API
traffic, while `pause` is small enough to pull on first use.

Patch and some read failures are only logged by kube-burner, not returned as
failures. The runner therefore exits **3** if `kube-burner.log` contains any
`level=error` line, even when kube-burner itself succeeded.

## Monitoring and cleanup

The runner saves a unique `results-<workload>-<timestamp>-*` directory containing:

- `kube-burner.log`: creation/readiness results and pod latency measurements.
- `baseline.txt`, `node-usage.txt`, `after.txt`: per-node CPU (millicores),
  memory (MiB), and percentages, before/during/after the run. All nodes are
  monitored, including control-plane nodes.
- `node-metrics.jsonl`: Metrics API snapshots with their original timestamps
  and sampling windows; CPU is a window average, memory is working set.
- `nodes.json`: node capacity/allocatable resources for interpreting samples.
- `metrics-baseline.json`: initial raw Metrics API response.
- `apiserver-metrics.tsv` (both workloads): `timestamp<TAB>series<TAB>value`
  samples from each control-plane API server's `/metrics` endpoint, taken at
  baseline, at each interval and after the run. Every series has a `member`
  label identifying the node. These include in-flight requests, API Priority and
  Fairness queued/executing/rejected requests, `apiserver_request_total` summed
  by verb and code, `apiserver_request_duration_seconds_{sum,count}` summed by
  verb, and API server process CPU seconds, resident memory and goroutines.
  It also includes the API server's view of etcd:
  `etcd_request_duration_seconds_{sum,count}` and `etcd_request_errors_total`
  summed by operation (get, list, create, update, delete...),
  `apiserver_storage_size_bytes` (etcd database size) and
  `apiserver_storage_objects` (total stored objects). Counters are cumulative:
  compare consecutive samples **for the same member** for rates, and divide the
  duration sum delta by the count delta for mean latency. Watch for `code="429"`
  or rising rejected requests (throttling) and 5xx codes.
- `etcd-metrics.tsv`: the same format, sampled from every etcd member with a
  `member` label (for example `etcd_server_is_leader{member="bench-cp-01"}`).
  Included: leader status and leader changes, proposals committed, applied,
  pending and failed, slow applies, database size and size in use, MVCC
  put/delete/range/txn counts, peer round-trip time, etcd process CPU and
  memory, and WAL fsync and backend commit durations, with histogram buckets.
- `etcd-errors.log`: present only when an etcd sample failed.
- `apiserver-targets.tsv`: the node names and direct HTTPS endpoints used for
  API server scrapes.

The runner discovers nodes labeled `node-role.kubernetes.io/control-plane`
and scrapes each node's IPv4 InternalIP on port 6443 using the existing
kubeconfig credentials and TLS verification. Run it from the jump host (or
another machine that can reach all control-plane IPs). It refuses to start if
discovery or any initial scrape fails. kube-burner still uses the kubeconfig's
endpoint, normally the HAProxy VIP. Scraping through that VIP would mix
counters from different servers and produce invalid rates. Older result files
without a `member` label sampled only the server answering the VIP.
The runner needs permission to read `/metrics` (cluster-admin has it).

### etcd metrics

The runner reads each member's metrics through the API server's pod proxy
(`/api/v1/namespaces/kube-system/pods/etcd-<node>:2381/proxy/metrics`). It needs
the same kubeconfig and cluster-admin access, and no direct network access to
the nodes. RKE2 serves etcd metrics only on `127.0.0.1:2381` unless the server
config contains `etcd-expose-metrics: true`. `../server-cloud-config.yml` sets this for
newly created servers; it then also listens, unauthenticated, on the node IP
port 2381 inside the isolated cluster network. Servers created before that
change need it once, one server at a time (etcd keeps quorum while one member
restarts):

```bash
# On each bench-cp-* node, waiting for the node to be Ready before the next one.
echo 'etcd-expose-metrics: true' | sudo tee -a /etc/rancher/rke2/config.yaml
sudo systemctl restart rke2-server
```

`ETCD_METRICS=auto` (default) samples etcd if every member answers at baseline,
otherwise it prints a warning and samples only the API server's etcd client
metrics. `ETCD_METRICS=required` refuses to start instead, and
`ETCD_METRICS=off` skips etcd sampling. A failed sample during the run is
recorded in `etcd-errors.log` and does not stop the benchmark.

To interpret the samples: WAL fsync p99 should stay below about 10 ms and backend
commit p99 below about 25 ms. Compute them from the bucket deltas between two
samples. Rising pending proposals or leader changes indicate etcd is the
bottleneck. Compare `etcd_request_duration_seconds` with the API server's request
latency to tell storage time from API server CPU time.

```bash
tail -f results-*/node-usage.txt
tail -f results-*/kube-burner.log
grep 'apiserver_request_total' results-api-intensive-*/apiserver-metrics.tsv | tail
grep 'etcd_server_proposals_pending' results-*/etcd-metrics.tsv | tail
```

Sampling uses metrics-server, not Prometheus, and may miss short spikes. It
measures actual usage rather than requests/limits; pod latency is reported by
kube-burner separately. There are no automatic usage thresholds or alerts.
If monitoring fails, the runner exits nonzero and terminates kube-burner rather
than silently continuing an unmonitored test.

`global.gc: true` removes the benchmark namespaces after a successful run.
kube-burner writes its log to `kube-burner.log` in the results directory only.
On interruption, timeout or failure, check for leftovers:

```bash
kubectl get namespaces | grep -E 'kubelet-density-heavy|api-intensive'
# Inspect the names first; delete only benchmark namespaces from this run.
kubectl delete namespace <benchmark-namespace>
```

The benchmark creates no persistent volumes. Removing its namespaces deletes
the test data. Results remain local. The runner does not install monitoring,
modify existing application workloads, or change node configuration.
