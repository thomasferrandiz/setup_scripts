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
   for readiness, then holds for `HOLD_DURATION`. With `PRE_CREATE_NAMESPACES=true`
   (the default), kube-burner first creates all namespaces, one at a time (about
   20 s for 2000 on the 1000-worker cluster), so the object creates are limited
   only by `QPS`/`BURST`. With `false`, each iteration waits for its own namespace
   create, which caps the loop at about 22 iterations/s whatever the QPS; results
   before this setting existed were produced that way.
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

- `parameters.env`: the effective run settings (`WORKLOAD`, `ITERATIONS`,
  `QPS`, `BURST`, `HOLD_DURATION`, `READ_ITERATIONS`, `PATCH_ITERATIONS`,
  `PRE_CREATE_NAMESPACES`, `TIMEOUT`, `SAMPLE_INTERVAL`, `ETCD_METRICS`, `KCM_METRICS`,
  `KUBELET_METRICS`, `CILIUM_METRICS`, `NODE_SAMPLE_COUNT`), the kubeconfig context and the
  start time, as `KEY=value` lines.
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
  To explain slow or timed-out creates it also records:
  - `apiserver_request_duration_seconds_{sum,count}{resource,verb}` for
    `services` and `ipaddresses` only. A Service create also allocates its
    ClusterIP by creating an `IPAddress` object through the API server itself;
  - `apiserver_request_terminations_total` by verb, resource and code: requests
    the API server stopped itself, for example `504` timeouts;
  - admission time: `apiserver_admission_step_admission_duration_seconds_{sum,count}`
    by type (`admit`/`validate`) and operation, and
    `apiserver_admission_{controller,webhook}_admission_duration_seconds_{sum,count}`
    by plugin or webhook name and operation;
  - ClusterIP allocation: `kube_apiserver_clusterip_allocator_allocation_duration_seconds_{sum,count}`,
    and `kube_apiserver_clusterip_allocator_allocation_total` and `..._errors_total` by scope.
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
- `kcm-metrics.tsv`: the same format, sampled from every kube-controller-manager
  with a `member` label (see
  [kube-controller-manager metrics](#kube-controller-manager-metrics)).
- `kcm-errors.log`: present only when a kube-controller-manager sample failed.
- `sampled-nodes.txt`, `kubelet-metrics.tsv`, `cilium-metrics.tsv`: the workers
  sampled for node-side metrics, and their kubelet and cilium-agent samples, with
  the node name as `member` (see
  [kubelet and cilium-agent metrics](#kubelet-and-cilium-agent-metrics)).
- `kubelet-errors.log`, `cilium-errors.log`: present only when a sample failed.
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

#### Defragmenting etcd

Defragment all etcd members before each run (see
[run 12](../kube-burner-results/1000wk_cilium_haproxy/run_12_analysis.md)), from
the jump host:

```bash
./defrag-etcd.sh
```

The script finds the `etcd-*` static pods, asks each member whether it is the
leader, and defragments the other members first and the leader last, one at a
time. It runs `etcdctl` directly in the pods (the etcd image has no shell) with
the RKE2 client certificates, and shows `endpoint status --cluster` before and
after. After defragmentation, `DB SIZE` should be close to `IN USE` on every
member. A member blocks reads and writes while it defragments, so run the
script before a benchmark, and before `rebalance.sh` if a control-plane node
also needs restarting. `DEFRAG_TIMEOUT` (default `120s`) sets the `etcdctl`
command timeout for each member. The script stops at the first failure.

### API server connection balancing

Kubelets, Cilium agents and kube-burner each keep long-lived HTTP/2 connections
to the API servers. After an API server restarts, it gets almost no connections
back: in run 10, bench-cp-02 had 5k goroutines against 80k on bench-cp-01, and
bench-cp-01 reached 98 % CPU. `../server-cloud-config.yml` sets this for newly
created servers:

```yaml
kube-apiserver-arg:
  - "goaway-chance=0.001"
```

The API server then answers about 1 request in 1,000 with an HTTP/2 GOAWAY, and
the client opens a new connection. For clients of the VIP, such as kube-burner
and kubectl, the new connection goes through HAProxy `leastconn`, so their
connections spread across the servers over a few minutes, at little cost.

goaway does **not** rebalance kubelets. They connect through the rke2-agent
local load balancer on `127.0.0.1:6443`, which stays on one server and moves only
when a connection to it fails, so after a GOAWAY the kubelet reconnects to the
same server. To spread kubelets, restart `rke2-agent` on the workers in batches
after a control-plane rolling restart, with `rebalance.sh` (see below).

Until run 11, Cilium agents used the same load balancer (`k8sServiceHost:
localhost`). In run 11, the server restarted first (bench-cp-02) kept about 88k
goroutines for the whole run, while bench-cp-03 had about 4k. Cilium now gets
two bootstrap URLs in `k8s.apiServerURLs`: the VIP and `127.0.0.1:6443`. With
more than one URL, the agent switches to the `kubernetes` Service
(`10.43.0.1:443`) once it has synced. Cilium's socket load balancer then picks a
random API server for every new connection, so goaway also spreads the agents.
`k8sServiceHost: localhost` stays, for the init containers. See
[Cilium API server high availability](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#kubernetes-api-server-high-availability).

To apply it to an existing cluster, add the values to the manifest on
bench-cp-01 (the chart has `rollOutCiliumPods: false`, so the agents must be
restarted to read the new ConfigMap):

```bash
# On bench-cp-01, under "valuesContent: |-", at the same indentation as ipv6:
sudo vi /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
#     k8s:
#       apiServerURLs: "https://192.168.64.253:6443 https://127.0.0.1:6443"
# From the jump host, once the helm-install-rke2-cilium job has completed:
kubectl -n kube-system get configmap cilium-config \
  -o jsonpath='{.data.k8s-api-server-urls}{"\n"}'
kubectl -n kube-system rollout restart daemonset/cilium deployment/cilium-operator
kubectl -n kube-system rollout status daemonset/cilium
```

Each agent then logs `updating kubernetes service mapping`, and `go_goroutines`
per API server should even out.

For existing servers, use a drop-in file, one server at a time:

```bash
# On each bench-cp-* node, waiting for the node to be Ready before the next one.
sudo mkdir -p /etc/rancher/rke2/config.yaml.d
sudo tee /etc/rancher/rke2/config.yaml.d/60-apiserver-goaway.yaml <<'EOF'
kube-apiserver-arg:
  - "goaway-chance=0.001"
EOF
sudo systemctl restart rke2-server
```

To compare how many connections each API server holds, look at `go_goroutines`
by member in `apiserver-metrics.tsv`.

#### Rebalancing after a control-plane restart

goaway takes hours to move idle agents: in run 12, bench-cp-02 gained only
2.4k goroutines in 25 minutes after its restart. After any control-plane
restart, and before a benchmark, run `rebalance.sh` from the jump host. It needs
`kubectl`, `jq` and SSH to the workers as `opensuse` (the jump host's
`~/.ssh/config` already uses `bench.key`):

```bash
./rebalance.sh
```

It shows `go_goroutines` per API server, restarts the Cilium DaemonSet and waits
for the rollout, then restarts `rke2-agent` on the Ready workers in parallel
batches, waits for each batch to be Ready, and shows `go_goroutines` again. It
stops at the first failed restart or batch that doesn't become Ready. Workers
keep running their pods while `rke2-agent` restarts.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CILIUM` | `yes` | Restart the Cilium agents. |
| `AGENTS` | `yes` | Restart `rke2-agent` on the workers. |
| `BATCH_SIZE` | `50` | Workers restarted at a time, 1 to 1000. |
| `READY_TIMEOUT` | `300` | Seconds to wait for a batch to be Ready. |
| `ROLLOUT_TIMEOUT` | `60m` | Timeout of the Cilium rollout. |
| `SSH_USER` | `opensuse` | SSH user on the workers. |

The restarted rke2-agent load balancer picks a pseudo-random server, so the
kubelets spread out but not perfectly evenly. Run the script again if one
server still has far fewer goroutines.

#### API Priority and Fairness for Cilium

The suggested `kube-system-service-accounts` FlowSchema puts every kube-system
ServiceAccount into the `workload-high` priority level, with flows distinguished
by namespace. All 1,000 Cilium agents and the operator are therefore one flow,
limited to the 6 queues of 50 requests its hand allows. When the agents
re-establish their watches, for example after an API server restart, many of
them get `429` queue-full responses and retry. `../rke2-server-sles.sh` writes
`cilium-apf.yaml` into the RKE2 manifests on bench-cp-01. It gives Cilium its
own priority level, with about 85 of the default 600 seats per API server and
one flow per ServiceAccount. Lease requests still match `system-leader-election`
first (precedence 100).

To apply it to an existing cluster, from the jump host:

```bash
kubectl apply -f - <<'EOF'
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: cilium
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 40
    lendablePercent: 50
    limitResponse:
      type: Queue
      queuing:
        queues: 64
        handSize: 8
        queueLengthLimit: 250
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: cilium
spec:
  priorityLevelConfiguration:
    name: cilium
  matchingPrecedence: 850
  distinguisherMethod:
    type: ByUser
  rules:
    - subjects:
        - kind: ServiceAccount
          serviceAccount:
            name: cilium
            namespace: kube-system
        - kind: ServiceAccount
          serviceAccount:
            name: cilium-operator
            namespace: kube-system
      resourceRules:
        - verbs: ["*"]
          apiGroups: ["*"]
          resources: ["*"]
          clusterScope: true
          namespaces: ["*"]
      nonResourceRules:
        - verbs: ["*"]
          nonResourceURLs: ["*"]
EOF
kubectl get flowschema,prioritylevelconfiguration cilium
```

The FlowSchema should show `MissingPL` as `False`. During a run, Cilium requests
appear under `priority_level="cilium"` in `apiserver-metrics.tsv`
(`apiserver_flowcontrol_current_executing_requests`,
`apiserver_flowcontrol_current_inqueue_requests` and
`apiserver_flowcontrol_rejected_requests_total`). To roll back, delete both
objects on the cluster and remove `cilium-apf.yaml` from the manifests
directory on bench-cp-01 (otherwise RKE2 creates them again):

```bash
sudo rm /var/lib/rancher/rke2/server/manifests/cilium-apf.yaml
kubectl delete flowschema cilium
kubectl delete prioritylevelconfiguration cilium
```

### kube-controller-manager metrics

The runner reads each kube-controller-manager's metrics through the API server's
pod proxy over HTTPS
(`/api/v1/namespaces/kube-system/pods/https:kube-controller-manager-<node>:10257/proxy/metrics`).
They show whether its controllers are slowed by their own client-side rate limit
(`kube-api-qps`, default 20, and `kube-api-burst`, default 30, per controller).
The log only reports waits longer than 1 s, and only some of them, so the absence
of `client-side throttling` log messages is not proof.

By default RKE2 binds port 10257 to `127.0.0.1` and requires authorization for
`/metrics`. `../server-cloud-config.yml` sets these for newly created servers:

```yaml
kube-controller-manager-arg:
  - "bind-address=0.0.0.0"
  - "authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics"
  - "kube-api-qps=100"
  - "kube-api-burst=200"
  - "concurrent-deployment-syncs=20"
  - "concurrent-replicaset-syncs=20"
```

kube-controller-manager then serves `/metrics` without authorization on port
10257 of the node IP, inside the isolated cluster network, as etcd does on port
2381. The last four values raise the controllers' client limits and worker
counts; with the defaults the leader spent ~225 ms per request waiting for its
own rate limiter (run 07). Existing servers need the setting once,
one server at a time. Use a drop-in file, because appending a second
`kube-controller-manager-arg` key to `config.yaml` would duplicate it:

```bash
# On each bench-cp-* node, waiting for the node to be Ready before the next one.
sudo mkdir -p /etc/rancher/rke2/config.yaml.d
sudo tee /etc/rancher/rke2/config.yaml.d/50-kcm-metrics.yaml <<'EOF'
kube-controller-manager-arg:
  - "bind-address=0.0.0.0"
  - "authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics"
  - "kube-api-qps=100"
  - "kube-api-burst=200"
  - "concurrent-deployment-syncs=20"
  - "concurrent-replicaset-syncs=20"
EOF
sudo systemctl restart rke2-server
```

If `config.yaml` already sets `kube-controller-manager-arg`, add the values
to that list instead. To check the new flags on the running process:

```bash
kubectl -n kube-system get pods -l component=kube-controller-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[0].args[*]}  {@}{"\n"}{end}{end}' \
  | grep -E 'kube-controller-manager-|kube-api-|concurrent-(deployment|replicaset)'
```

`KCM_METRICS=auto` (default) samples kube-controller-manager if it answers at
baseline, otherwise it prints a warning and continues without it.
`KCM_METRICS=required` refuses to start instead, and `KCM_METRICS=off` skips it.
A failed sample during the run is recorded in `kcm-errors.log` and does not
stop the benchmark.

Sampled series (all with a `member` label):

- `rest_client_rate_limiter_duration_seconds_{sum,count}` by verb, and its
  `_bucket` by `le`: the time requests waited for the client-side rate limiter,
  summed over all controllers.
- `rest_client_request_duration_seconds_{sum,count}` by verb, and
  `rest_client_requests_total` by method and code (including `409` conflicts).
- `workqueue_depth`, `workqueue_adds_total`, `workqueue_retries_total` and
  `workqueue_queue_duration_seconds_{sum,count}` by queue `name`, for example
  `deployment`, `replicaset` or `endpointslice`.
- `leader_election_master_status` (1 on the leader; only the leader runs
  controllers), process CPU seconds and resident memory.

To interpret them, take deltas between consecutive samples of the leader. The
mean rate-limiter wait is the `_sum` delta divided by the `_count` delta. A mean
wait of tens of milliseconds or more, or a `_sum` that grows by more seconds than
the sample interval, means the controllers were throttled. A growing
`workqueue_depth{name="deployment"}` while the API server is idle, with a large
`workqueue_queue_duration_seconds` mean, shows a controller backlog. If the
backlog grows without throttling, the cause is elsewhere, for example the
controller's worker count (`concurrent-deployment-syncs`, 20 here, default 5).

```bash
grep 'leader_election_master_status' results-*/kcm-metrics.tsv | tail -3
grep 'rest_client_rate_limiter_duration_seconds_sum' results-*/kcm-metrics.tsv | tail
grep 'workqueue_depth{member="bench-cp-01",name="deployment"}' results-*/kcm-metrics.tsv
```

### kubelet and cilium-agent metrics

When kube-burner reports a high pod `Ready` latency while `PodScheduled` is low,
the time is spent on the node. The runner samples `NODE_SAMPLE_COUNT` (default 5,
at most 100) workers, evenly spaced in natural name order (with 1000 workers:
`bench-wk-01`, `-201`, `-401`, `-601`, `-801`), and lists them in
`sampled-nodes.txt`. Pods land on any worker, so a few nodes are representative,
and the sampling cost stays independent of cluster size.

- **kubelet**, through the API server's node proxy
  (`/api/v1/nodes/<node>/proxy/metrics`). This needs no cluster change, only the
  `nodes/proxy` permission (cluster-admin has it).
- **cilium-agent**, through the pod proxy on port 9962
  (`/api/v1/namespaces/kube-system/pods/<cilium-pod>:9962/proxy/metrics`). The
  agent serves metrics only with `prometheus.enabled: true` in the rke2-cilium
  chart values, which `../rke2-server-sles.sh` sets for new clusters. The agent
  pods are resolved once at baseline; an agent that restarts during the run
  then shows up in `cilium-errors.log`.

To enable the agent metrics on an existing cluster, add the values to the
manifest that `../rke2-server-sles.sh` wrote on bench-cp-01. RKE2 watches that
directory and applies the change; editing the HelmChartConfig with kubectl alone
would be reverted from this file.

```bash
# On bench-cp-01, under "valuesContent: |-", at the same indentation as ipv6:
sudo vi /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
#     prometheus:
#       enabled: true
# Then, from the jump host:
kubectl -n kube-system get helmchartconfig rke2-cilium -o jsonpath='{.spec.valuesContent}'
kubectl -n kube-system rollout status daemonset/cilium
```

This changes the agent DaemonSet (a new host port), so every agent restarts,
two nodes at a time by default (`updateStrategy.rollingUpdate.maxUnavailable: 2`).
With 1000 workers that takes a long time. To go faster, also set
`updateStrategy: {rollingUpdate: {maxUnavailable: 10%}}` in the same values.
Existing pods keep their network while their agent restarts.

`KUBELET_METRICS` and `CILIUM_METRICS` work like `KCM_METRICS`: `auto`
(default) samples if every sampled node answers at baseline and warns
otherwise, `required` refuses to start, and `off` skips the component.

Sampled kubelet series:

- `kubelet_run_podsandbox_duration_seconds_{sum,count}` and `_bucket` by `le`,
  and `kubelet_run_podsandbox_errors_total`: sandbox creation, which includes
  the CNI ADD and therefore the wait for cilium-agent.
- `kubelet_runtime_operations_duration_seconds_{sum,count}` and
  `kubelet_runtime_operations_errors_total` by `operation_type`
  (`run_podsandbox`, `create_container`, `start_container`, `pull_image`...).
- `kubelet_pod_start_duration_seconds_{sum,count}` and
  `kubelet_pod_start_sli_duration_seconds_{sum,count}` (without image pulls),
  `kubelet_pod_worker_duration_seconds_{sum,count}` by `operation_type`,
  `kubelet_pleg_relist_duration_seconds_{sum,count}`, and `kubelet_running_pods`
  and `kubelet_running_containers`.
- The kubelet's API client: `rest_client_rate_limiter_duration_seconds_{sum,count}`
  and `rest_client_request_duration_seconds_{sum,count}` by verb, and
  `rest_client_requests_total` by method and code. Rejected status updates show
  up here as `429`s.
- Process CPU seconds and resident memory.

Sampled cilium-agent series:

- `cilium_endpoint_regeneration_time_stats_seconds_{sum,count}` by `scope`,
  `cilium_endpoint_regenerations_total` by `outcome`, and `cilium_endpoint_state`
  by `endpoint_state` (endpoints stuck in `waiting-for-identity` or
  `regenerating`).
- The agent API rate limiter, which paces CNI ADD calls (`api_call="endpoint-create"`):
  `cilium_api_limiter_processed_requests_total` by `api_call` and `outcome`,
  and `cilium_api_limiter_{wait_duration_seconds,processing_duration_seconds,requests_in_flight,rate_limit,adjustment_factor}`
  by `api_call` and `value` (mean, min, max, limit...).
- `cilium_agent_api_process_time_seconds_{sum,count}` by method and path.
- The agent's Kubernetes client: `cilium_k8s_client_api_calls_total` by host,
  method and return code, and `cilium_k8s_client_{api_latency_time,rate_limiter_duration}_seconds_{sum,count}`
  by method.
- `cilium_identity` by type, `cilium_policy_regeneration_total`,
  `cilium_errors_warnings_total` by level, process CPU seconds and resident memory.

To interpret them, compare the deltas per member during pod creation. A mean
`run_podsandbox` duration (`_sum` delta divided by `_count` delta) close to the
pod `Ready` latency puts the delay in the CNI. A large mean
`cilium_api_limiter_wait_duration_seconds{api_call="endpoint-create"}` points to
the agent's API rate limiter. A long endpoint regeneration time or many
`waiting-for-identity` endpoints points to identity allocation. `429`s or a
large rate-limiter wait in `cilium_k8s_client_*` point to the agent's
Kubernetes client. The `host` label shows which address the client used: with
`k8s.apiServerURLs`, calls should move from the bootstrap URLs
(`192.168.64.253:6443` or `127.0.0.1:6443`) to the `kubernetes` Service
(`10.43.0.1:443`) once the agent has synced.

```bash
cat results-*/sampled-nodes.txt
grep 'kubelet_run_podsandbox_duration_seconds_sum' results-*/kubelet-metrics.tsv | tail
grep 'cilium_api_limiter_wait_duration_seconds' results-*/cilium-metrics.tsv | grep endpoint-create | tail
grep 'cilium_endpoint_state' results-*/cilium-metrics.tsv | tail
```

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
