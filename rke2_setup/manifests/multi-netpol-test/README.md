# MultiNetworkPolicy Test Kit

Executable manifests and scripts implementing
[multi-network-policy-test-plan.md](../multi-network-policy-test-plan.md).

## Layout

```
multi-netpol-test/
├── 00-namespaces.yaml            # mnp-test-a (mnp-test=true), mnp-test-b (mnp-test=false)
├── 01-network-attachments.yaml   # test-net-a (policy target), test-net-b (isolation control)
├── 02-workloads.yaml             # server, client, client-b, client-other-ns pods
├── policies/
│   ├── static/                   # ready-to-apply MultiNetworkPolicy manifests, one per case
│   ├── templates/                # policies needing a runtime IP substitution (ipBlock cases)
│   └── invalid/                  # deliberately invalid manifests for admission tests
└── scripts/
    ├── lib.sh                       # shared helpers (apply, checks, IP discovery, assertions)
    ├── 00-install-controller.sh     # install CRD + nftables controller
    ├── 10-deploy-topology.sh        # deploy namespaces/attachments/pods, discover IPs
    ├── 15-admission-tests.sh        # MNP-001..004 (CRD schema/admission)
    ├── 20-ingress-tests.sh          # MNP-005..010 (ingress enforcement)
    ├── 25-egress-tests.sh           # MNP-011..012 (egress enforcement)
    ├── 30-policytype-and-union-tests.sh # MNP-013..014
    ├── 35-lifecycle-tests.sh        # MNP-015..016
    ├── 40-isolation-tests.sh        # MNP-017
    ├── 45-node-recovery-tests.sh    # MNP-018
    ├── 50-custom-rule-test.sh       # MNP-020
    ├── run-all.sh                   # runs everything above in order
    └── 90-cleanup.sh                # tears the test topology down
```

MNP-019 (dual-stack) is not automated here because IPv6 ranges are
cluster-specific; see "Dual-stack (MNP-019)" below to adapt the kit
manually.

## Prerequisites

* `kubectl` and `jq` on the machine running the scripts.
* A cluster with Multus and `whereabouts` IPAM installed, and nodes able to
  run privileged DaemonSets.
* Edit the `master` field in
  [01-network-attachments.yaml](./01-network-attachments.yaml) if your
  nodes' physical interface is not `eth0` (see
  [multus_demo_nad.yaml](../multus_demo_nad.yaml) for the existing
  convention this is modeled on).
* The `wbitt/network-multitool:extra` image (used for all test pods) must
  be pullable from the cluster; it provides `nc` and `socat`, both used
  directly by the test scripts and pod listeners.

## Running

```sh
cd rke2_setup/manifests/multi-netpol-test/scripts

# One-shot, full suite:
./run-all.sh

# Or step by step:
./00-install-controller.sh
./10-deploy-topology.sh
./15-admission-tests.sh
./20-ingress-tests.sh
./25-egress-tests.sh
./30-policytype-and-union-tests.sh
./35-lifecycle-tests.sh
./40-isolation-tests.sh
./45-node-recovery-tests.sh
./50-custom-rule-test.sh

# Tear down the test topology (add --all to also remove the CRD/controller):
./90-cleanup.sh
```

Each script prints `PASS`/`FAIL`/`N/A` lines with the expected vs. actual
result for every assertion, and ends with a summary line. `run-all.sh`
aggregates the per-stage results and exits non-zero if any stage reported a
failure.

Useful environment variables (set before running any script):

| Variable | Default | Purpose |
| --- | --- | --- |
| `RECONCILE_WAIT` | `8` | Fallback fixed sleep, used only when `wait_reconcile` is called without a policy namespace/name (e.g. after a label change or a policy deletion). |
| `RECONCILE_TIMEOUT` | `45` | Max seconds to actively poll controller logs for a confirmed reconcile when `wait_reconcile NAMESPACE NAME` is used. |
| `RECONCILE_POLL_INTERVAL` | `3` | Seconds between log-polling attempts within `RECONCILE_TIMEOUT`. |
| `RECONCILE_SETTLE_WAIT` | `8` | Extra sleep *after* a confirmed reconcile log line, before trusting enforcement is actually live. See below for why this exists. |
| `REPEAT_CHECK_INTERVAL` | `2` | Seconds between attempts within `repeat_check`, so retries are spread over real time instead of firing back-to-back. |
| `CONTROLLER_NAMESPACE` | `kube-system` | Namespace the `multi-networkpolicy-nftables` DaemonSet runs in. |
| `CONTROLLER_LABEL_SELECTOR` | `name=multi-networkpolicy-nftables` | Label selector used to find controller pods for log polling. |
| `CONNECT_TIMEOUT` | `3` | Seconds for a single connect attempt. |
| `CHECK_RETRIES` | `3` | Times each check is repeated; disagreement is reported as `flaky(...)`. |

**Why `wait_reconcile` does more than sleep:** most call sites pass a policy
namespace/name (e.g. `wait_reconcile mnp-test-a mnp-ingress-deny-all`).
Instead of blindly sleeping, `wait_reconcile` polls every
`multi-networkpolicy-nftables` controller pod's logs until each one has
logged `MultiNetworkPolicy reconciled successfully` for that object. This
was added after a real run of this kit surfaced a controller-side race: each
DaemonSet pod runs its own independent watch over the cluster-wide
`MultiNetworkPolicy` CRD, and one node's controller can silently miss a
Create/Update event for a policy it's responsible for enforcing (no error,
no reconcile log at all for that object on that node), leaving the target
pod's nftables chains at their default-accept state with no drop rule ever
installed. A fixed sleep can't detect that; it just makes every subsequent
"deny" assertion fail, looking like an enforcement bug when only one node's
watch missed the event. If confirmation doesn't show up within
`RECONCILE_TIMEOUT`, `wait_reconcile` re-annotates the policy (forcing a
fresh watch event) and checks once more before giving up and continuing.

**Why there's also a `RECONCILE_SETTLE_WAIT` after confirmation:** on a real
RKE2/macvlan cluster we also observed a second, distinct timing gap: the
controller logs `MultiNetworkPolicy reconciled successfully` immediately
after it hands its nftables transaction to the kernel via netlink (and the
reconcile log confirmed the transaction text was fully correct - managed
interfaces set, the `input -> jump ingress` dispatcher rule, per-policy
chain, etc.) - but connections made in the few seconds right after that log
line could still observe the old (pre-policy) behavior. Because
`repeat_check`'s retries used to fire back-to-back with no delay between
them, all of them landed inside that same short stale window and agreed on
the same wrong answer, so the harness never even reported it as `flaky`. If
you still see denies failing after this, check
`kubectl logs -n kube-system -l name=multi-networkpolicy-nftables` for the
policy name to confirm whether every controller pod actually reconciled it.

Results and generated files (discovered IPs, rendered templates, ConfigMap
backups) are written to `multi-netpol-test/results/`, which is safe to
delete after cleanup.

## Dual-stack (MNP-019)

To exercise MNP-019, add an IPv6 `whereabouts` range to both NADs in
[01-network-attachments.yaml](./01-network-attachments.yaml) (a second
entry in the `plugins[0].ipam` block, or a second whereabouts-managed
range depending on your whereabouts version), redeploy the topology, and
re-run `20-ingress-tests.sh` / `25-egress-tests.sh` after extending
`get_net_ip` calls or manually discovering the IPv6 addresses via
`kubectl get pod ... -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks-status}'`.
This is left manual because the IPv6 prefix must be chosen per cluster.

## Notes on flakiness and evidence

* `tcp_check`/`udp_check` run from inside the pods with `kubectl exec`, so
  they exercise the real attached interface rather than a service or the
  primary network.
* Every check is repeated `CHECK_RETRIES` times; a disagreement between
  repeats is reported as `flaky(...)` rather than silently picking one
  result - treat any `flaky` line as needing manual follow-up.
* For audit evidence, capture `kubectl get multi-networkpolicies -A -o yaml`
  and controller logs after each stage, as documented in
  [multi-network-policy-test-plan.md](../multi-network-policy-test-plan.md).
