# MultiNetworkPolicy Test Kit (rke2-multus chart)

Runs the same test cases as [multi-netpol-test](../multi-netpol-test/README.md)
(implementing [multi-network-policy-test-plan.md](../multi-network-policy-test-plan.md)),
but against the multi-networkpolicy-nftables controller deployed by an
`rke2-multus` chart tarball (`.tgz`) instead of the upstream
[deploy-multi-netpol.yaml](../deploy-multi-netpol.yaml) manifest.

The topology manifests and MultiNetworkPolicy fixtures are shared with
[multi-netpol-test](../multi-netpol-test/) (`00-namespaces.yaml`,
`01-network-attachments.yaml`, `02-workloads.yaml`, `policies/`); only the
scripts differ.

## Layout

```
multi-netpol-test-chart/
├── values-mnp.yaml               # values layered on the release: enables multiNetworkPolicy
└── scripts/
    ├── lib.sh                       # shared helpers + helm/chart helpers
    ├── 00-install-chart.sh          # helm upgrade --install the chart under test
    ├── 10-deploy-topology.sh        # deploy namespaces/attachments/pods, discover IPs
    ├── 15-admission-tests.sh        # MNP-001..004 (CRD schema/admission)
    ├── 20-ingress-tests.sh          # MNP-005..010 (ingress enforcement)
    ├── 25-egress-tests.sh           # MNP-011..012 (egress enforcement)
    ├── 30-policytype-and-union-tests.sh # MNP-013..014
    ├── 35-lifecycle-tests.sh        # MNP-015..016
    ├── 40-isolation-tests.sh        # MNP-017
    ├── 45-node-recovery-tests.sh    # MNP-018
    ├── 50-custom-rule-test.sh       # MNP-020, through chart values
    ├── run-all.sh                   # runs everything above in order
    └── 90-cleanup.sh                # tears the test topology down (--all: roll the chart back)
```

## Prerequisites

Everything listed in [multi-netpol-test](../multi-netpol-test/README.md#prerequisites), plus:

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

# Or step by step:
./00-install-chart.sh /path/to/rke2-multus-<version>.tgz
./10-deploy-topology.sh
./15-admission-tests.sh
./20-ingress-tests.sh
./25-egress-tests.sh
./30-policytype-and-union-tests.sh
./35-lifecycle-tests.sh
./40-isolation-tests.sh
./45-node-recovery-tests.sh
./50-custom-rule-test.sh   # reuses the tarball recorded by 00-install-chart.sh

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

Results and generated files (discovered IPs, chart install state, values
files) are written to `multi-netpol-test-chart/results/`. Keep
`chart-install.env` until `90-cleanup.sh --all` has run, as it holds the
revision to roll back to.
