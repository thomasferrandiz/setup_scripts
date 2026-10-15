# OpenTofu environments

This folder provisions throwaway AWS VMs for trying out different Kubernetes
flavors (k3s, RKE2, Rancher, kubeadm, ...) using cloud-init scripts.
It also includes a standalone [Harvester configuration](harvester/main.tf).

## Harvester VMs

The `harvester/` configuration uses `harvester/harvester` 1.9.0 to create
`default/bench-cp-01`, `default/bench-cp-02`, and `default/bench-cp-03`.
Each VM has 8 vCPUs, 16 GiB RAM, a 40 GiB virtio boot disk cloned from
`default/image-x49tz`, a virtio bridge interface on
`default/vm-net-2085`, a USB tablet, the q35 machine type, and the
`RerunOnFailure` run strategy.
Resource requests match the manifest: 500m CPU and 16 GiB memory. A node
selector requires `network.harvesterhci.io/cluster-net=true`, equivalent
to the manifest's required single-value node affinity.
The image, its `longhorn-image-x49tz` storage class, network, and
`default/tferrandiz` SSH key must already exist.

Save the Harvester kubeconfig as `harvester/local.yaml` (its current context
is used), and the cloud-init template as `harvester/cloud-config.yml`.
Both files are ignored by Git because they contain credentials. OpenTofu
creates a Harvester cloud-init secret for each VM, avoiding Harvester's 2 KiB
limit on inline cloud-init user data. Each VM gets its own hostname, and its
secret contains the RKE2 bootstrap configuration and script. Each VM gets a
new boot volume named `<vm-name>-disk-0`.

With OpenTofu or Terraform >= 1.5:

```sh
cd opentofu/harvester
tofu init -upgrade
tofu plan -out=harvester.tfplan
# Review the plan before applying.
tofu apply harvester.tfplan
```

Expect three new VMs and no imports. The VM names and boot-volume names
must be available in the `default` namespace; if the example VM still
exists, choose unused names in `for_each` before applying.
`prevent_destroy` protects the VMs against planned destruction/replacement.
Disks have `auto_delete = false`, so their data is retained if a VM is
subsequently deleted outside OpenTofu.

Provider 1.9.0 still does not expose the manifest's custom `bench-cp` pod
anti-affinity, 120-second termination grace period, or
`LiveMigrateIfPossible` eviction strategy. New VMs use provider/Harvester
defaults for those settings, so this is not an exact YAML reproduction.
The manifest's preferred anti-affinity would only encourage placement on
different hosts, not guarantee it; the provider cannot reproduce that
specific preference.

Cloud-init contents (including password hashes) are stored in local state
and saved plans even when marked sensitive. Protect those files; they are
ignored by Git. Regenerate any saved plan after changing this configuration.
The AWS wrapper scripts do not manage this configuration.

### TLS hostname mismatch in test environments

The Harvester provider honors the kubeconfig's `insecure-skip-tls-verify`
setting. To bypass a TLS hostname mismatch in a trusted test environment,
add it to the relevant cluster in `harvester/local.yaml`:

```yaml
clusters:
  - name: your-cluster
    cluster:
      server: https://your-harvester-endpoint
      insecure-skip-tls-verify: true
```

Keep the existing server URL, cluster name, credentials, and contexts.
Remove `certificate-authority` or `certificate-authority-data` from that
same cluster block if present. Regenerate and review the plan before applying:

```sh
tofu -chdir=harvester plan -out=harvester.tfplan
tofu -chdir=harvester apply harvester.tfplan
```

Run these commands from `opentofu/`.

**Warning:** this disables both certificate-chain and hostname verification,
exposing the connection and credentials to impersonation attacks. Use it
only for a trusted test environment. Fixing the endpoint's certificate to
match its hostname and using a trusted CA is preferable; once fixed,
remove the insecure setting and restore the CA configuration if required.

## Layout

```
opentofu/
├── infraup.sh              # bring infrastructure up
├── infradown.sh            # tear infrastructure down
├── aws/                    # base, variable-driven config (most flavors)
│   ├── main.tf
│   ├── variables.tf
│   ├── terraform.tfvars.example
│   ├── demo/               # demo-gpu variant (own VPC + GPU node)
│   └── cni-test/           # test-cni variant (multus / dual CIDR)
└── cloud-init-scripts/     # per-flavor bootstrap scripts
    ├── rke2-server.sh      # RKE2 server (bootstrap or HA join)
    ├── rke2-agent.sh       # RKE2 agent
    ├── k3s-server.sh       # k3s server
    ├── k3s-agent.sh        # k3s agent
    └── *-sles.sh           # SLES 16 equivalents of the above
```

Instead of copying a `.tf.template` and running `sed` on placeholders, each
config is a normal, committed OpenTofu config. `infraup.sh` selects the
cloud-init script(s) and instance count by passing the `cloud_init_files`
variable — the number of VMs is derived from the length of that list.

## Prerequisites

- [OpenTofu](https://opentofu.org/) (`tofu`)
- `jq` and GNU `sed` (`brew install gnu-sed` → `gsed`, used by `infraup.sh`)
- AWS credentials (see below)
- An existing VPC **with an IPv6 CIDR** for the base `aws/` config; its ID goes
  into `vpc_id`. The `demo/` and `cni-test/` variants create their own VPC.

## Credentials and variables

Credentials are read from the standard AWS credential chain by default
(environment variables, shared config, SSO, instance profiles). The
recommended approach:

```sh
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...        # if using temporary credentials
```

Alternatively, copy the example tfvars and fill it in (kept out of git):

```sh
cp aws/terraform.tfvars.example aws/terraform.tfvars
# edit aws/terraform.tfvars (at minimum set vpc_id)
```

Variables (base `aws/` config):

| Variable           | Required | Default                       | Notes                                        |
| ------------------ | -------- | ----------------------------- | -------------------------------------------- |
| `region`           | no       | `eu-south-2`                  | AWS region                                   |
| `vpc_id`           | yes      | —                             | Existing VPC with an IPv6 CIDR               |
| `access_key`       | no       | `null`                        | Falls back to the credential chain           |
| `secret_key`       | no       | `null`                        | Falls back to the credential chain           |
| `token`            | no       | `null`                        | Falls back to the credential chain           |
| `cloud_init_files` | yes      | —                             | One script per VM; normally set by infraup   |
| `os`               | no       | `ubuntu`                      | `ubuntu` or `sles16`                         |
| `sles_ami`         | no       | `ami-0d2945b6b30408829`       | SLES 16 AMI ID (region-specific)             |
| `cni`              | no       | `canal`                       | CNI plugin for RKE2; set by infraup.sh       |
| `rke2_token`       | no       | `secret`                      | Shared join token                            |

## Usage

```sh
cd opentofu
./infraup.sh <flavor> [cni] [multus]
```

Available flavors:

| Flavor              | OS     | Config         | VMs | Notes                                   |
| ------------------- | ------ | -------------- | --- | --------------------------------------- |
| `k3s-aws`           | Ubuntu | `aws/`         | 3   | k3s                                     |
| `k3s-sles`          | SLES16 | `aws/`         | 3   | k3s on SLES 16                          |
| `rancher-aws`       | Ubuntu | `aws/`         | 2   | k3s + Rancher                           |
| `rancher-prime-aws` | Ubuntu | `aws/`         | 2   | k3s + Rancher Prime                     |
| `kubeadm`           | Ubuntu | `aws/`         | 2   | kubeadm                                 |
| `rke2`              | Ubuntu | `aws/`         | 2   | RKE2; 2nd arg = CNI, 3rd arg = `multus` |
| `rke2-sles`         | SLES16 | `aws/`         | 2   | RKE2 on SLES 16; same CNI/multus args   |
| `rke2-ha`           | Ubuntu | `aws/`         | 5   | RKE2 HA (3 servers + 2 agents)          |
| `rke2-ha-sles`      | SLES16 | `aws/`         | 5   | RKE2 HA on SLES 16                      |
| `test-cni`          | Ubuntu | `aws/cni-test` | 3   | CNI test with multus/secondary CIDR     |

The CNI plugin (`canal` (default), `calico`, `cilium`, `flannel`, `none`) is
passed via `-var="cni=..."` — no file is generated or modified. Append `multus`
as a third argument to layer multus on top:

```sh
./infraup.sh rke2 cilium multus
```

## Tearing down

```sh
./infradown.sh <flavor>
```

Accepts the same flavor names as `infraup.sh`. It runs `tofu destroy` with the
correct number of placeholder entries for `cloud_init_files` so the state is
cleanly destroyed without needing the original scripts on disk.

## Notes

- To debug OpenTofu:

  ```sh
  TF_LOG=DEBUG tofu -chdir=aws apply
  ```

- State is local (`terraform.tfstate` in each config directory) and gitignored.
- The AWS provider is pinned to `~> 5.0`.
