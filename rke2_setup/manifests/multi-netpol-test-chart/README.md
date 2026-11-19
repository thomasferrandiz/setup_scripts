# MultiNetworkPolicy Test Kit (rke2-multus chart)

Runs the same test cases as [multi-netpol-test](../multi-netpol-test/README.md)
(implementing [multi-network-policy-test-plan.md](../multi-network-policy-test-plan.md)),
but against the multi-networkpolicy-nftables controller deployed by an
`rke2-multus` chart tarball (`.tgz`) instead of the upstream
[deploy-multi-netpol.yaml](../deploy-multi-netpol.yaml) manifest.

The topology manifests and MultiNetworkPolicy fixtures are shared with
[multi-netpol-test](../multi-netpol-test/) (`00-namespaces.yaml`,
`01-network-attachments.yaml`, `02-workloads.yaml`, `policies/`); only the
scripts differ. The attachments are rendered into `results/` with
`NAD_TYPE`/`NAD_MASTER` applied (see below).

## Layout

```
multi-netpol-test-chart/
├── values-mnp.yaml               # values layered on the release: enables multiNetworkPolicy
├── multi-netpol-test-chart-plan.yaml # chart test plan (F13/F15/F24 below come from it)
├── policies/                     # chart-kit-only fixtures (F24 NetworkPolicy)
└── scripts/
    ├── lib.sh                       # shared helpers + helm/chart helpers
    ├── 00-install-chart.sh          # helm upgrade --install the chart under test
    ├── 05-prime-render-test.sh      # P1, Prime image rendering (helm template only)
    ├── 10-deploy-topology.sh        # deploy namespaces/attachments/pods, discover IPs
    ├── 15-admission-tests.sh        # MNP-001..004 (CRD schema/admission)
    ├── 20-ingress-tests.sh          # MNP-005..010 (ingress enforcement)
    ├── 25-egress-tests.sh           # MNP-011..012 (egress enforcement)
    ├── 30-policytype-and-union-tests.sh # MNP-013..014
    ├── 35-lifecycle-tests.sh        # MNP-015..016
    ├── 40-isolation-tests.sh        # MNP-017
    ├── 42-networkpolicy-coexistence-test.sh # F24, NetworkPolicy on eth0 + MultiNetworkPolicy
    ├── 45-node-recovery-tests.sh    # MNP-018
    ├── 50-custom-rule-test.sh       # MNP-020, through chart values
    ├── 55-network-plugins-test.sh   # F13, networkPlugins, through chart values
    ├── 60-icmp-test.sh              # F15, acceptICMP, through chart values
    ├── 65-prime-images-test.sh      # P1, Prime images pulled from systemDefaultRegistry
    ├── run-all.sh                   # runs everything above in order
    └── 90-cleanup.sh                # tears the test topology down (--all: roll the chart back)
```

## Prerequisites

Everything listed in [multi-netpol-test](../multi-netpol-test/README.md#prerequisites), plus:

* `kernel-default` on every worker that runs test pods (control-plane
  nodes tainted `CriticalAddonsOnly` don't run them). The `macvlan` and
  `ipvlan` kernel modules used by the test attachments are only in
  `kernel-default`. Minimal openSUSE/SLES images, such as the
  `opensuse-156-minimal` image of the Harvester bench VMs
  ([opentofu/harvester](../../../opentofu/harvester/)), ship
  `kernel-default-base` instead, so the test pods stay in
  `ContainerCreating` with `failed to create macvlan: operation not
  supported` (`failed to create ipvlan` with `NAD_TYPE=ipvlan`). On each
  worker, one at a time:

  ```sh
  sudo zypper --non-interactive install kernel-default   # keeps kernel-default-base
  sudo reboot
  # once the node is Ready again:
  sudo modprobe macvlan && sudo modprobe ipvlan && lsmod | grep -E '^(macvlan|ipvlan) '
  ```

  The reboot restarts every pod on the node. Recreate pods that failed
  before the fix with `./90-cleanup.sh` and `./10-deploy-topology.sh`.
* If the node interface is not `eth0`, set `NAD_MASTER` instead of editing
  the shared `01-network-attachments.yaml`.
* whereabouts IPAM: `values-mnp.yaml` enables the chart's
  `rke2-whereabouts` subchart, so the kit installs it.
* `helm` (v3.14+ or v4, for `--reset-then-reuse-values`) on the machine
  running the scripts, with a kubeconfig allowed to manage releases in
  `kube-system`.
* The `rke2-multus` chart to test, as a `.tgz` (e.g. from `helm package`
  or the rke2-charts build). It must contain the `multiNetworkPolicy`
  values.
* The controller image referenced by the chart must be pullable. Override it
  if needed, e.g.
  `HELM_EXTRA_ARGS="--set multiNetworkPolicy.image.repository=... --set multiNetworkPolicy.image.tag=..."`.

## How the chart is installed

The chart's cluster-scoped objects (ClusterRoles `rke2-multus`,
`rke2-multus-mnp`, ...) have fixed names, so it cannot be installed as a
second release next to the cluster's Multus. `00-install-chart.sh` therefore
upgrades the existing `rke2-multus` release in `kube-system` (or installs
it if absent):

```sh
helm upgrade --install rke2-multus <tgz> -n kube-system \
  --reset-then-reuse-values -f values-mnp.yaml $HELM_EXTRA_ARGS
```

`--reset-then-reuse-values` starts from the new chart's defaults and keeps
the values the release was installed with (e.g. by the RKE2
helm-controller: `global.systemDefaultRegistry`, ...), so Multus itself
keeps its configuration and only the controller is turned on.

Other details:

* The release revision before the upgrade and the tarball path are saved
  in `results/chart-install.env`; `90-cleanup.sh --all` rolls back to that
  revision (or uninstalls the release if it did not exist).
* Helm never installs `crds/` on upgrade and RKE2 ships CRDs in the
  separate `rke2-multus-crd` chart. If the MultiNetworkPolicy CRD is
  missing, it is applied from the tarball's `crds/` directory and removed
  again by `90-cleanup.sh --all`.
* On RKE2 the release is owned by the `HelmChart` `kube-system/rke2-multus`.
  Restarting RKE2 or changing that HelmChart/HelmChartConfig during a run
  redeploys the packaged chart over the one under test.

## Running

```sh
cd rke2_setup/manifests/multi-netpol-test-chart/scripts

# One-shot, full suite:
./run-all.sh /path/to/rke2-multus-<version>.tgz

# With ipvlan attachments instead of macvlan:
NAD_TYPE=ipvlan ./run-all.sh /path/to/rke2-multus-<version>.tgz

# Or step by step:
./00-install-chart.sh /path/to/rke2-multus-<version>.tgz
./05-prime-render-test.sh  # no cluster access, reuses the recorded tarball
./10-deploy-topology.sh
./15-admission-tests.sh
./20-ingress-tests.sh
./25-egress-tests.sh
./30-policytype-and-union-tests.sh
./35-lifecycle-tests.sh
./40-isolation-tests.sh
./42-networkpolicy-coexistence-test.sh
./45-node-recovery-tests.sh
./50-custom-rule-test.sh   # reuses the tarball recorded by 00-install-chart.sh
./55-network-plugins-test.sh   # idem
./60-icmp-test.sh              # idem
./65-prime-images-test.sh      # idem; PRIME_TEST_DNC=1 to also test the DNC

# Tear down the test topology (add --all to also roll the rke2-multus release back):
./90-cleanup.sh
```

Output, assertions and flakiness handling are the same as in
[multi-netpol-test](../multi-netpol-test/README.md#running), including why
`wait_reconcile` polls the controller logs for
`MultiNetworkPolicy reconciled successfully` (logged at `info`, the chart's
default `logLevel`).

Environment variables, in addition to the `RECONCILE_*`,
`REPEAT_CHECK_INTERVAL`, `CONNECT_TIMEOUT` and `CHECK_RETRIES` ones of
[multi-netpol-test](../multi-netpol-test/README.md#running):

| Variable | Default | Purpose |
| --- | --- | --- |
| `CHART_TGZ` | first argument | Chart tarball for `00-install-chart.sh` / `run-all.sh`. |
| `HELM_RELEASE` | `rke2-multus` | Release to upgrade. The controller DaemonSet is `<release>-mnp` and the custom rules ConfigMap `<release>-mnp-custom-rules`. |
| `HELM_NAMESPACE` | `kube-system` | Namespace of the release and of the controller. |
| `CHART_VALUES` | `../values-mnp.yaml` | Values file layered on the release by every helm upgrade. |
| `HELM_EXTRA_ARGS` | (empty) | Extra helm arguments (word-split) for every upgrade, e.g. image overrides. |
| `CONTROLLER_LABEL_SELECTOR` | `app=rke2-multus-mnp` | Label selector used to find controller pods. |
| `NAD_TYPE` | `macvlan` | CNI plugin of `test-net-a`/`test-net-b`: `macvlan` (bridge mode) or `ipvlan` (L2 mode). Must be in the controller's `multiNetworkPolicy.networkPlugins` (both are by default); `10-deploy-topology.sh` checks it and recreates the test pods when the attachments change. A node interface cannot hold macvlan and ipvlan sub-interfaces at once (`device or resource busy`), so other pods using the other type on the same nodes block the switch. |
| `NAD_MASTER` | `eth0` | Node interface the attachments are created on. |
| `PRIME_REGISTRY` | `registry.rancher.com` | `global.systemDefaultRegistry` for `65-prime-images-test.sh`. Must serve the hardened images without credentials. |
| `PRIME_TEST_DNC` | `0` | `1` makes `65-prime-images-test.sh` also enable and check the dynamic networks controller (with the thick plugin). |

## MNP-020 custom rules through chart values

Instead of patching a ConfigMap, `50-custom-rule-test.sh` sets
`multiNetworkPolicy.customRules.ingress.v4` to `tcp dport 9999 drop` with a
helm upgrade and checks that the chart:

* renders it as `custom-v4-ingress-rules.txt` in
  `<release>-mnp-custom-rules`, with no egress/v6 files;
* passes only `--custom-v4-ingress-rule-file` to the controller;
* changes the pod template `checksum/custom-rules` annotation, so every
  controller pod is replaced by the upgrade alone (the controller only reads
  the rule files at startup).

It then runs the same traffic checks as the upstream suite and restores
the previous value, checking that the ConfigMap and the rule file flags
are removed when no custom rules remain.

## Chart test plan cases (P1, F13, F15, F24)

These cases from [multi-netpol-test-chart-plan.yaml](multi-netpol-test-chart-plan.yaml)
use the plan's IDs:

* **P1** (`05-prime-render-test.sh`, rendering only): RKE2 Prime passes
  `global.prime.enabled=true` and `global.systemDefaultRegistry` to its
  charts. The script renders the chart with `helm template`, with mnp and the
  dynamic networks controller enabled (DNC needs `thickPlugin.enabled=true`).
  It checks that both DaemonSets use
  `<systemDefaultRegistry>/<primeRepository>:<primeTag>` (the chart defaults),
  with no prefix when the registry is empty, and the mirrored images when
  Prime is off. The registry is `PRIME_TEST_REGISTRY`
  (default `registry.example.com`). The chart is the first argument,
  `CHART_TGZ`, or the tarball recorded by `00-install-chart.sh`. It does not
  check that the images are actually pulled from the registry.
* **P1** (`65-prime-images-test.sh`, on the cluster): upgrades the release
  with `global.prime.enabled=true` and
  `global.systemDefaultRegistry=$PRIME_REGISTRY` (default
  `registry.rancher.com`, which allows anonymous pulls). It checks that the
  mnp DaemonSet and its running pods use
  `<registry>/<primeRepository>:<primeTag>`, with an image ID from that
  registry, that every DaemonSet of the release (multus, whereabouts) uses
  the registry, and that the hardened controller enforces MNP-007. It then
  rolls the release back to its previous revision with `helm rollback` and
  checks the images are restored. With `PRIME_TEST_DNC=1` it also enables
  the dynamic networks controller, which needs the thick plugin and the
  multus ConfigMap. Every multus pod is then replaced on upgrade and again on
  rollback, so the switch is opt-in. RKE2's own `prime: true` would switch
  every system chart, which is why the test sets the values on this release
  only.
* **F24** (`42-networkpolicy-coexistence-test.sh`): a Kubernetes
  `NetworkPolicy` ([policies/np-f24-allow-client-b.yaml](policies/np-f24-allow-client-b.yaml))
  allows only `app=client-b` to reach the server on eth0, while MNP-007 allows
  only `app=client` on test-net-a. It checks every combination (neither, NetworkPolicy only,
  both, MultiNetworkPolicy only). Each interface must follow its own policy.
  This needs a primary CNI that enforces NetworkPolicy (canal, Cilium,
  Calico).
* **F13** (`55-network-plugins-test.sh`): removes `NAD_TYPE` from
  `multiNetworkPolicy.networkPlugins` with a helm upgrade. If no plugin is
  left, it uses `bridge`. It then applies the MNP-006 ingress deny-all policy. The controller logs
  `Network type is not supported` and traffic stays allowed. After restoring
  the list, the replaced controller pods enforce the existing policy. It
  reuses the test attachments instead of a separate bridge NAD, which would
  only connect pods on the same node.
* **F15** (`60-icmp-test.sh`): under the MNP-006 ingress deny-all policy,
  ping to the server succeeds and TCP is denied with `acceptICMP=true`
  (`--accept-icmp`). With `acceptICMP=false`, both are denied.

`55` and `60` restore the previous value on exit. The value is then stored
as a user-supplied value on the release, at its effective value (usually the
chart default). Use `90-cleanup.sh --all` to roll the release back.

Results and generated files (discovered IPs, chart install state, values
files) are written to `multi-netpol-test-chart/results/`. Keep
`chart-install.env` until `90-cleanup.sh --all` has run, as it holds the
revision to roll back to.
