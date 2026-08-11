# OpenTofu environments

This folder provisions throwaway AWS VMs for trying out different Kubernetes
flavors (k3s, RKE2, Rancher, kubeadm, ...) using cloud-init scripts.

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

| Variable           | Required | Default       | Notes                                        |
| ------------------ | -------- | ------------- | -------------------------------------------- |
| `region`           | no       | `eu-south-2`  | AWS region                                   |
| `vpc_id`           | yes      | —             | Existing VPC with an IPv6 CIDR               |
| `access_key`       | no       | `null`        | Falls back to the credential chain           |
| `secret_key`       | no       | `null`        | Falls back to the credential chain           |
| `token`            | no       | `null`        | Falls back to the credential chain           |
| `cloud_init_files` | yes      | —             | One script per VM; normally set by infraup   |

## Usage

```sh
cd opentofu
./infraup.sh <flavor> [cni] [multus]
```

Available flavors:

| Flavor              | Config        | VMs | Notes                                  |
| ------------------- | ------------- | --- | -------------------------------------- |
| `k3s-aws`           | `aws/`        | 3   | k3s                                    |
| `rancher-aws`       | `aws/`        | 2   | k3s + Rancher                          |
| `rancher-prime-aws` | `aws/`        | 2   | k3s + Rancher Prime                    |
| `kubeadm`           | `aws/`        | 2   | kubeadm                                |
| `rke2`              | `aws/`        | 2   | RKE2; 2nd arg = CNI, 3rd arg = `multus`|
| `rke2-ha`           | `aws/`        | 5   | RKE2 in HA mode                        |
| `demo-gpu`          | `aws/demo/`   | 3   | SUSECON demo + GPU node                |
| `test-cni`          | `aws/cni-test`| 3   | CNI test with multus/secondary CIDR    |

For `rke2`, the CNI plugin (`canal` (default), `calico`, `cilium`, `flannel`,
`none`) is injected into a generated copy of `installRKE2_0.sh` under
`cloud-init-scripts/generated/` (gitignored) — the tracked script is never
modified in place. Append `multus` as a third argument to layer multus on top:

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
