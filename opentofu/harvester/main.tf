terraform {
  required_version = ">= 1.5.0"
  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "1.9.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "harvester" {
  kubeconfig = "${path.module}/local.yaml"
}

provider "random" {}

resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

variable "rke2_api_vip" {
  description = "Static vm-net-2085 address that kube-vip announces on the RKE2 servers for the API (6443) and supervisor (9345). Workers join through it."
  type        = string
  default     = "192.168.64.253"

  validation {
    condition     = can(cidrhost("${var.rke2_api_vip}/32", 0)) && cidrhost("192.168.64.0/19", 0) == cidrhost("${var.rke2_api_vip}/19", 0)
    error_message = "rke2_api_vip must be an IPv4 address in vm-net-2085 (192.168.64.0/19)."
  }
}

variable "rke2_worker_count" {
  description = "Number of RKE2 worker (agent) VMs, named bench-wk-01, bench-wk-02, ..."
  type        = number
  default     = 50

  validation {
    condition     = var.rke2_worker_count >= 0 && var.rke2_worker_count <= 99 && floor(var.rke2_worker_count) == var.rke2_worker_count
    error_message = "rke2_worker_count must be an integer between 0 and 99."
  }
}

variable "rke2_agent_version" {
  description = "RKE2 version installed on the workers. Agents must not be newer than the servers; keep it equal to the server version."
  type        = string
  default     = "v1.36.5+rke2r1"
}

locals {
  rke2_bootstrap_node = "bench-cp-01"
  rke2_worker_nodes   = toset([for i in range(1, var.rke2_worker_count + 1) : format("bench-wk-%02d", i)])
  rke2_joining_nodes  = toset(["bench-cp-02", "bench-cp-03"])

  # Joining servers register directly with the bootstrap server: the Harvester
  # load balancer cannot reach backends on the isolated vm-net-2085 network.
  rke2_bootstrap_ip = harvester_virtualmachine.bench_bootstrap.network_interface[0].ip_address

  rke2_cloud_config_vars = {
    rke2_token         = random_password.rke2_token.result
    rke2_server_script = file("${path.module}/rke2-server-sles.sh")
    bench_public_key   = trimspace(file("${path.module}/bench.key.pub"))
    rke2_api_vip       = var.rke2_api_vip
    kube_vip_manifest = templatefile("${path.module}/kube-vip.yaml", {
      rke2_api_vip = var.rke2_api_vip
    })
  }
}

moved {
  from = harvester_cloudinit_secret.bench["bench-cp-01"]
  to   = harvester_cloudinit_secret.bench_bootstrap
}

moved {
  from = harvester_virtualmachine.bench["bench-cp-01"]
  to   = harvester_virtualmachine.bench_bootstrap
}

resource "harvester_cloudinit_secret" "bench_bootstrap" {
  name      = "${local.rke2_bootstrap_node}-cloudinit"
  namespace = "default"
  user_data = sensitive(templatefile("${path.module}/cloud-config.yml", merge(local.rke2_cloud_config_vars, {
    node_name      = local.rke2_bootstrap_node
    server_address = ""
  })))
}

resource "harvester_cloudinit_secret" "bench" {
  for_each = local.rke2_joining_nodes

  name      = "${each.key}-cloudinit"
  namespace = "default"
  user_data = sensitive(templatefile("${path.module}/cloud-config.yml", merge(local.rke2_cloud_config_vars, {
    node_name      = each.key
    server_address = local.rke2_bootstrap_ip
  })))

  lifecycle {
    precondition {
      condition     = local.rke2_bootstrap_ip != null && local.rke2_bootstrap_ip != ""
      error_message = "${local.rke2_bootstrap_node} has no IP address; joining servers need it as their RKE2 server address."
    }
  }
}

resource "harvester_virtualmachine" "bench_bootstrap" {
  name      = local.rke2_bootstrap_node
  namespace = "default"
  labels = {
    "node-role" = "control-plane"
  }
  cpu          = 8
  memory       = "16Gi"
  machine_type = "q35"
  run_strategy = "RerunOnFailure"
  ssh_keys     = ["default/tferrandiz"]

  node_selector = {
    "network.harvesterhci.io/cluster-net" = "true"
  }

  requests {
    cpu    = "500m"
    memory = "16Gi"
  }

  network_interface {
    name         = "default"
    network_name = "default/vm-net-2085"
    model        = "virtio"
    type         = "bridge"
    # Creation waits for the DHCP address the joining servers connect to.
    wait_for_lease = true
  }

  disk {
    name               = "disk-0"
    type               = "disk"
    size               = "40Gi"
    bus                = "virtio"
    boot_order         = 1
    image              = "default/image-x49tz"
    storage_class_name = "longhorn-image-x49tz"
    access_mode        = "ReadWriteMany"
    volume_mode        = "Block"
    volume_name        = "${local.rke2_bootstrap_node}-disk-0"
    auto_delete        = true
  }

  input {
    name = "tablet"
    type = "tablet"
    bus  = "usb"
  }

  cloudinit {
    type                  = "noCloud"
    user_data_secret_name = harvester_cloudinit_secret.bench_bootstrap.name
  }
}

resource "harvester_virtualmachine" "bench" {
  for_each = local.rke2_joining_nodes

  name      = each.key
  namespace = "default"
  labels = {
    "node-role" = "control-plane"
  }
  cpu          = 8
  memory       = "16Gi"
  machine_type = "q35"
  run_strategy = "RerunOnFailure"
  ssh_keys     = ["default/tferrandiz"]

  node_selector = {
    "network.harvesterhci.io/cluster-net" = "true"
  }

  requests {
    cpu    = "500m"
    memory = "16Gi"
  }

  network_interface {
    name         = "default"
    network_name = "default/vm-net-2085"
    model        = "virtio"
    type         = "bridge"
  }

  disk {
    name               = "disk-0"
    type               = "disk"
    size               = "40Gi"
    bus                = "virtio"
    boot_order         = 1
    image              = "default/image-x49tz"
    storage_class_name = "longhorn-image-x49tz"
    access_mode        = "ReadWriteMany"
    volume_mode        = "Block"
    volume_name        = "${each.key}-disk-0"
    auto_delete        = true
  }

  input {
    name = "tablet"
    type = "tablet"
    bus  = "usb"
  }

  cloudinit {
    type                  = "noCloud"
    user_data_secret_name = harvester_cloudinit_secret.bench[each.key].name
  }

}

# Workers join through the kube-vip VIP rather than a specific server.
resource "harvester_cloudinit_secret" "bench_worker" {
  for_each = local.rke2_worker_nodes

  name      = "${each.key}-cloudinit"
  namespace = "default"
  user_data = sensitive("#cloud-config\n${yamlencode({
    hostname            = each.key
    ssh_authorized_keys = [data.harvester_ssh_key.bench_dual_network.public_key]
    users = [{
      name        = "opensuse"
      lock_passwd = true
      shell       = "/bin/bash"
      sudo        = "ALL=(ALL) NOPASSWD:ALL"
      groups      = "users"
      ssh_authorized_keys = [
        data.harvester_ssh_key.bench_dual_network.public_key,
        trimspace(file("${path.module}/bench.key.pub")),
      ]
    }]
    write_files = [
      {
        path        = "/usr/local/sbin/rke2-agent-sles.sh"
        owner       = "root:root"
        permissions = "0755"
        content     = file("${path.module}/rke2-agent-sles.sh")
      },
      {
        path        = "/etc/rancher/rke2/config.yaml"
        owner       = "root:root"
        permissions = "0600"
        content = yamlencode({
          server    = "https://${var.rke2_api_vip}:9345"
          token     = random_password.rke2_token.result
          node-name = each.key
        })
      }
    ]
    package_update = true
    packages       = ["qemu-guest-agent", "curl"]
    runcmd = [
      ["systemctl", "enable", "--now", "qemu-guest-agent.service"],
      ["/usr/local/sbin/rke2-agent-sles.sh", var.rke2_agent_version],
    ]
  })}")
}

resource "harvester_virtualmachine" "bench_worker" {
  for_each = local.rke2_worker_nodes

  name      = each.key
  namespace = "default"
  labels = {
    "node-role" = "worker"
  }
  cpu          = 1
  memory       = "2Gi"
  machine_type = "q35"
  run_strategy = "RerunOnFailure"
  ssh_keys     = ["default/tferrandiz"]

  node_selector = {
    "network.harvesterhci.io/cluster-net" = "true"
  }

  requests {
    cpu    = "500m"
    memory = "2Gi"
  }

  network_interface {
    name         = "default"
    network_name = "default/vm-net-2085"
    model        = "virtio"
    type         = "bridge"
  }

  disk {
    name               = "disk-0"
    type               = "disk"
    size               = "20Gi"
    bus                = "virtio"
    boot_order         = 1
    image              = "default/image-x49tz"
    storage_class_name = "longhorn-image-x49tz"
    access_mode        = "ReadWriteMany"
    volume_mode        = "Block"
    volume_name        = "${each.key}-disk-0"
    auto_delete        = true
  }

  input {
    name = "tablet"
    type = "tablet"
    bus  = "usb"
  }

  cloudinit {
    type                  = "noCloud"
    user_data_secret_name = harvester_cloudinit_secret.bench_worker[each.key].name
  }
}

data "harvester_ssh_key" "bench_dual_network" {
  name      = "tferrandiz"
  namespace = "default"
}

# Stored in a secret so the private key is not embedded in the VM spec.
resource "harvester_cloudinit_secret" "bench_dual_network" {
  name      = "bench-net-01-cloudinit"
  namespace = "default"
  user_data = sensitive("#cloud-config\n${yamlencode({
    hostname            = "bench-net-01"
    ssh_authorized_keys = [data.harvester_ssh_key.bench_dual_network.public_key]
    users = [{
      name                = "opensuse"
      lock_passwd         = true
      shell               = "/bin/bash"
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
      groups              = "users"
      ssh_authorized_keys = [data.harvester_ssh_key.bench_dual_network.public_key]
    }]
    # Deferred so the files are written after the opensuse user exists.
    write_files = [
      {
        path        = "/home/opensuse/.ssh/bench.key"
        owner       = "opensuse:users"
        permissions = "0600"
        content     = file("${path.module}/bench.key")
        defer       = true
      },
      {
        path        = "/home/opensuse/.ssh/bench.key.pub"
        owner       = "opensuse:users"
        permissions = "0644"
        content     = file("${path.module}/bench.key.pub")
        defer       = true
      },
      {
        path        = "/home/opensuse/.ssh/config"
        owner       = "opensuse:users"
        permissions = "0600"
        content     = "Host *\n  IdentityFile ~/.ssh/bench.key\n"
        defer       = true
      }
    ]
    package_update = true
    packages       = ["qemu-guest-agent"]
    runcmd = [
      ["systemctl", "enable", "--now", "qemu-guest-agent.service"],
      # Keep the default route on eth0 (vm-net): vm-net-2085 is not reachable
      # from the R&D network, so replies routed through eth1 would be lost.
      ["sh", "-c", "grep -q '^DHCLIENT_SET_DEFAULT_ROUTE=' /etc/sysconfig/network/ifcfg-eth1 || echo \"DHCLIENT_SET_DEFAULT_ROUTE='no'\" >> /etc/sysconfig/network/ifcfg-eth1"],
      ["systemctl", "restart", "wicked"],
    ]
  })}")
}

resource "harvester_virtualmachine" "bench_dual_network" {
  name         = "bench-net-01"
  namespace    = "default"
  cpu          = 1
  memory       = "2Gi"
  machine_type = "q35"
  run_strategy = "RerunOnFailure"
  ssh_keys     = ["default/tferrandiz"]

  node_selector = {
    "network.harvesterhci.io/cluster-net" = "true"
  }

  requests {
    cpu    = "500m"
    memory = "2Gi"
  }

  network_interface {
    name         = "default"
    network_name = "default/vm-net"
    model        = "virtio"
    type         = "bridge"
  }

  network_interface {
    name         = "vm-net-2085"
    network_name = "default/vm-net-2085"
    model        = "virtio"
    type         = "bridge"
  }

  disk {
    name               = "disk-0"
    type               = "disk"
    size               = "20Gi"
    bus                = "virtio"
    boot_order         = 1
    image              = "default/image-x49tz"
    storage_class_name = "longhorn-image-x49tz"
    access_mode        = "ReadWriteMany"
    volume_mode        = "Block"
    volume_name        = "bench-net-01-disk-0"
    auto_delete        = true
  }

  input {
    name = "tablet"
    type = "tablet"
    bus  = "usb"
  }

  cloudinit {
    type = "noCloud"
    network_data = yamlencode({
      version = 1
      config = [
        {
          type    = "physical"
          name    = "eth0"
          subnets = [{ type = "dhcp4" }]
        },
        {
          type    = "physical"
          name    = "eth1"
          subnets = [{ type = "dhcp4" }]
        }
      ]
    })
    user_data_secret_name = harvester_cloudinit_secret.bench_dual_network.name
  }
}

output "virtual_machines" {
  description = "Harvester VM IDs, runtime states, and assigned hosts."
  value = merge(
    {
      for name, vm in merge(
        { (local.rke2_bootstrap_node) = harvester_virtualmachine.bench_bootstrap },
        harvester_virtualmachine.bench,
        harvester_virtualmachine.bench_worker
        ) : name => {
        id         = vm.id
        state      = vm.state
        node       = vm.node_name
        ip_address = try(vm.network_interface[0].ip_address, null)
      }
    },
    {
      "bench-net-01" = {
        id         = harvester_virtualmachine.bench_dual_network.id
        state      = harvester_virtualmachine.bench_dual_network.state
        node       = harvester_virtualmachine.bench_dual_network.node_name
        ip_address = try(harvester_virtualmachine.bench_dual_network.network_interface[0].ip_address, null)
      }
    }
  )
}
