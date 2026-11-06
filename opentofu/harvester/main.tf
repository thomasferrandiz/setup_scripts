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
  description = "Static vm-net-2085 VIP managed by Keepalived on the HAProxy VMs for the API (6443) and supervisor (9345). Reserve it outside DHCP allocation."
  type        = string
  default     = "192.168.64.253"

  validation {
    condition     = can(cidrhost("${var.rke2_api_vip}/32", 0)) && cidrhost("192.168.64.0/19", 0) == cidrhost("${var.rke2_api_vip}/19", 0)
    error_message = "rke2_api_vip must be an IPv4 address in vm-net-2085 (192.168.64.0/19)."
  }
}

variable "rke2_worker_count" {
  description = "Number of RKE2 worker (agent) VMs, named bench-wk-01, bench-wk-02, ... Use scale-workers.sh to add them in Ready-gated batches of 50."
  type        = number
  default     = 1000

  validation {
    condition     = var.rke2_worker_count >= 0 && var.rke2_worker_count <= 1000 && floor(var.rke2_worker_count) == var.rke2_worker_count
    error_message = "rke2_worker_count must be an integer between 0 and 1000."
  }
}

variable "rke2_agent_version" {
  description = "RKE2 version installed on the workers. Agents must not be newer than the servers; keep it equal to the server version."
  type        = string
  default     = "v1.36.5+rke2r1"
}

variable "rke2_control_plane" {
  description = "Control-plane topology. stacked: bench-cp-01..03 run etcd and the control plane. dedicated-etcd: bench-etcd-01..03 run only etcd and bench-cp-01..03 only the control plane. Convert a running stacked cluster with migrate-to-dedicated-etcd.sh, and add bench-cp-03 to a running dedicated-etcd cluster with two control-plane servers with add-control-plane-server.sh, not by changing this value. Required: a wrong value destroys the other topology's servers, so it has no default."
  type        = string

  validation {
    condition     = contains(["stacked", "dedicated-etcd"], var.rke2_control_plane)
    error_message = "rke2_control_plane must be stacked or dedicated-etcd."
  }
}

variable "control_plane_cpu" {
  description = "vCPUs of the servers that run the control plane (roles all and control-plane). etcd-only servers keep 8. Changing it updates the VMs in place without restarting them; restart each VM (virtctl restart) for the new size to take effect."
  type        = number
  default     = 16

  validation {
    condition     = var.control_plane_cpu >= 1 && floor(var.control_plane_cpu) == var.control_plane_cpu
    error_message = "control_plane_cpu must be a positive integer."
  }
}

variable "control_plane_memory" {
  description = "Memory of the servers that run the control plane (roles all and control-plane), e.g. 16Gi. etcd-only servers keep 16Gi. Like control_plane_cpu, it takes effect when the VM restarts."
  type        = string
  default     = "16Gi"

  validation {
    condition     = can(regex("^[1-9][0-9]*Gi$", var.control_plane_memory))
    error_message = "control_plane_memory must be a whole number of Gi, e.g. 16Gi."
  }
}

variable "rke2_server_roles" {
  description = "Overrides the servers derived from rke2_control_plane with node name => role (all, etcd or control-plane). Set by migrate-to-dedicated-etcd.sh for its intermediate steps; leave unset otherwise."
  type        = map(string)
  default     = null

  validation {
    condition = var.rke2_server_roles == null ? true : alltrue([
      for name, role in var.rke2_server_roles :
      can(regex("^bench-(cp|etcd)-0[1-9]$", name)) && contains(["all", "etcd", "control-plane"], role)
    ])
    error_message = "rke2_server_roles keys must be bench-cp-NN or bench-etcd-NN and roles all, etcd or control-plane."
  }
}

locals {
  rke2_cluster_cidr = "10.44.0.0/14"
  rke2_topologies = {
    stacked = {
      "bench-cp-01" = "all"
      "bench-cp-02" = "all"
      "bench-cp-03" = "all"
    }
    dedicated-etcd = {
      "bench-etcd-01" = "etcd"
      "bench-etcd-02" = "etcd"
      "bench-etcd-03" = "etcd"
      "bench-cp-01"   = "control-plane"
      "bench-cp-02"   = "control-plane"
      "bench-cp-03"   = "control-plane"
    }
  }
  rke2_server_roles = var.rke2_server_roles != null ? var.rke2_server_roles : local.rke2_topologies[var.rke2_control_plane]
  # The first server must run etcd: bench-cp-01 while it still does, otherwise bench-etcd-01.
  rke2_bootstrap_node = lookup(local.rke2_server_roles, "bench-cp-01", "") == "all" ? "bench-cp-01" : "bench-etcd-01"
  # Etcd-only joiners are a separate resource: control-plane servers render their addresses.
  rke2_etcd_joining_nodes = { for name, role in local.rke2_server_roles : name => role if name != local.rke2_bootstrap_node && role == "etcd" }
  rke2_joining_nodes      = { for name, role in local.rke2_server_roles : name => role if name != local.rke2_bootstrap_node && role != "etcd" }
  rke2_server_cpu         = { for name, role in local.rke2_server_roles : name => role == "etcd" ? 8 : var.control_plane_cpu }
  rke2_server_memory      = { for name, role in local.rke2_server_roles : name => role == "etcd" ? "16Gi" : var.control_plane_memory }
  rke2_worker_nodes       = toset([for i in range(1, var.rke2_worker_count + 1) : format("bench-wk-%02d", i)])
  rke2_lb_nodes           = { "bench-lb-01" = 150, "bench-lb-02" = 100 }
  rke2_server_ips = merge(
    { (local.rke2_bootstrap_node) = local.rke2_bootstrap_ip },
    { for name, vm in harvester_virtualmachine.bench_etcd : name => vm.network_interface[0].ip_address },
    { for name, vm in harvester_virtualmachine.bench : name => vm.network_interface[0].ip_address }
  )
  # Control-plane-only API servers connect to these etcd members directly
  # rather than through the RKE2 etcd proxy on 127.0.0.1:2379, which drops all
  # connections to a member when one supervisor health probe times out.
  rke2_etcd_servers = concat(
    local.rke2_server_roles[local.rke2_bootstrap_node] == "etcd" ? ["https://${local.rke2_bootstrap_ip}:2379"] : [],
    [for name, vm in harvester_virtualmachine.bench_etcd : "https://${vm.network_interface[0].ip_address}:2379"]
  )
  # HAProxy only forwards to servers running the API server; etcd-only nodes have none.
  rke2_apiserver_ips = {
    for name, ip in local.rke2_server_ips : name => ip
    if local.rke2_server_roles[name] != "etcd"
  }
  haproxy_config = templatefile("${path.module}/haproxy.cfg", {
    servers = local.rke2_apiserver_ips
  })

  # Direct registration avoids a dependency cycle: HAProxy needs all server leases.
  rke2_bootstrap_ip = harvester_virtualmachine.bench_bootstrap.network_interface[0].ip_address

  rke2_cloud_config_vars = {
    rke2_token           = random_password.rke2_token.result
    rke2_server_script   = file("${path.module}/rke2-server-sles.sh")
    bench_public_key     = trimspace(file("${path.module}/bench.key.pub"))
    harvester_public_key = data.harvester_ssh_key.bench_dual_network.public_key
    rke2_api_vip         = var.rke2_api_vip
    rke2_cluster_cidr    = local.rke2_cluster_cidr
    etcd_servers         = []
  }
}

resource "harvester_cloudinit_secret" "bench_bootstrap" {
  name      = "${local.rke2_bootstrap_node}-cloudinit"
  namespace = "default"
  user_data = sensitive(templatefile("${path.module}/server-cloud-config.yml", merge(local.rke2_cloud_config_vars, {
    node_name      = local.rke2_bootstrap_node
    server_address = ""
    rke2_role      = local.rke2_server_roles[local.rke2_bootstrap_node]
  })))

  lifecycle {
    precondition {
      condition     = contains(["all", "etcd"], lookup(local.rke2_server_roles, local.rke2_bootstrap_node, ""))
      error_message = "The servers must include ${local.rke2_bootstrap_node} with an etcd role: the first server must run etcd."
    }
    precondition {
      condition     = anytrue([for role in values(local.rke2_server_roles) : role != "etcd"])
      error_message = "At least one server must run the control plane (role all or control-plane)."
    }
  }
}

resource "harvester_cloudinit_secret" "bench_etcd" {
  for_each = local.rke2_etcd_joining_nodes

  name      = "${each.key}-cloudinit"
  namespace = "default"
  user_data = sensitive(templatefile("${path.module}/server-cloud-config.yml", merge(local.rke2_cloud_config_vars, {
    node_name      = each.key
    server_address = local.rke2_bootstrap_ip
    rke2_role      = each.value
  })))

  lifecycle {
    precondition {
      condition     = local.rke2_bootstrap_ip != null && local.rke2_bootstrap_ip != ""
      error_message = "${local.rke2_bootstrap_node} has no IP address; joining servers need it as their RKE2 server address."
    }
  }
}

resource "harvester_cloudinit_secret" "bench" {
  for_each = local.rke2_joining_nodes

  name      = "${each.key}-cloudinit"
  namespace = "default"
  # Cloud-init only applies this on first boot; use-direct-etcd.sh pushes
  # etcd-servers to running control-plane servers.
  user_data = sensitive(templatefile("${path.module}/server-cloud-config.yml", merge(local.rke2_cloud_config_vars, {
    node_name      = each.key
    server_address = local.rke2_bootstrap_ip
    rke2_role      = each.value
    etcd_servers   = local.rke2_etcd_servers
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
    "node-role" = local.rke2_server_roles[local.rke2_bootstrap_node] == "etcd" ? "etcd" : "control-plane"
  }
  cpu          = local.rke2_server_cpu[local.rke2_bootstrap_node]
  memory       = local.rke2_server_memory[local.rke2_bootstrap_node]
  machine_type = "q35"
  run_strategy = "RerunOnFailure"
  ssh_keys     = ["default/tferrandiz"]

  node_selector = {
    "network.harvesterhci.io/cluster-net" = "true"
  }

  requests {
    cpu    = "500m"
    memory = local.rke2_server_memory[local.rke2_bootstrap_node]
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
    # Etcd-only disks hold the only copy of the cluster data: keep them if the VM is destroyed.
    auto_delete = local.rke2_server_roles[local.rke2_bootstrap_node] != "etcd"
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
  cpu          = local.rke2_server_cpu[each.key]
  memory       = local.rke2_server_memory[each.key]
  machine_type = "q35"
  run_strategy = "RerunOnFailure"
  ssh_keys     = ["default/tferrandiz"]

  node_selector = {
    "network.harvesterhci.io/cluster-net" = "true"
  }

  requests {
    cpu    = "500m"
    memory = local.rke2_server_memory[each.key]
  }

  network_interface {
    name           = "default"
    network_name   = "default/vm-net-2085"
    model          = "virtio"
    type           = "bridge"
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

resource "harvester_virtualmachine" "bench_etcd" {
  for_each = local.rke2_etcd_joining_nodes

  name      = each.key
  namespace = "default"
  labels = {
    "node-role" = "etcd"
  }
  cpu          = local.rke2_server_cpu[each.key]
  memory       = local.rke2_server_memory[each.key]
  machine_type = "q35"
  run_strategy = "RerunOnFailure"
  ssh_keys     = ["default/tferrandiz"]

  node_selector = {
    "network.harvesterhci.io/cluster-net" = "true"
  }

  requests {
    cpu    = "500m"
    memory = local.rke2_server_memory[each.key]
  }

  network_interface {
    name           = "default"
    network_name   = "default/vm-net-2085"
    model          = "virtio"
    type           = "bridge"
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
    volume_name        = "${each.key}-disk-0"
    # The only copies of the cluster data: keep them if the VM is destroyed.
    auto_delete = false
  }

  input {
    name = "tablet"
    type = "tablet"
    bus  = "usb"
  }

  cloudinit {
    type                  = "noCloud"
    user_data_secret_name = harvester_cloudinit_secret.bench_etcd[each.key].name
  }

}

# Etcd-only joiners were in bench before bench_etcd existed.
moved {
  from = harvester_cloudinit_secret.bench["bench-etcd-01"]
  to   = harvester_cloudinit_secret.bench_etcd["bench-etcd-01"]
}

moved {
  from = harvester_virtualmachine.bench["bench-etcd-01"]
  to   = harvester_virtualmachine.bench_etcd["bench-etcd-01"]
}

moved {
  from = harvester_cloudinit_secret.bench["bench-etcd-02"]
  to   = harvester_cloudinit_secret.bench_etcd["bench-etcd-02"]
}

moved {
  from = harvester_virtualmachine.bench["bench-etcd-02"]
  to   = harvester_virtualmachine.bench_etcd["bench-etcd-02"]
}

moved {
  from = harvester_cloudinit_secret.bench["bench-etcd-03"]
  to   = harvester_cloudinit_secret.bench_etcd["bench-etcd-03"]
}

moved {
  from = harvester_virtualmachine.bench["bench-etcd-03"]
  to   = harvester_virtualmachine.bench_etcd["bench-etcd-03"]
}

resource "harvester_cloudinit_secret" "bench_lb" {
  for_each = local.rke2_lb_nodes

  name      = "${each.key}-cloudinit"
  namespace = "default"
  user_data = sensitive(templatefile("${path.module}/load-balancer-cloud-config.yml", {
    node_name            = each.key
    bench_public_key     = trimspace(file("${path.module}/bench.key.pub"))
    harvester_public_key = data.harvester_ssh_key.bench_dual_network.public_key
    haproxy_config       = local.haproxy_config
    keepalived_config = templatefile("${path.module}/keepalived.conf", {
      rke2_api_vip = var.rke2_api_vip
      priority     = each.value
    })
  }))

  lifecycle {
    precondition {
      condition     = alltrue([for ip in values(local.rke2_apiserver_ips) : ip != null && ip != ""])
      error_message = "All control-plane VMs must have DHCP addresses before rendering HAProxy backends."
    }
  }
}

resource "harvester_virtualmachine" "bench_lb" {
  for_each = local.rke2_lb_nodes

  name         = each.key
  namespace    = "default"
  labels       = { "node-role" = "load-balancer" }
  cpu          = 2
  memory       = "4Gi"
  machine_type = "q35"
  run_strategy = "RerunOnFailure"
  ssh_keys     = ["default/tferrandiz"]

  node_selector = {
    "network.harvesterhci.io/cluster-net" = "true"
  }

  requests {
    cpu    = "500m"
    memory = "4Gi"
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
    user_data_secret_name = harvester_cloudinit_secret.bench_lb[each.key].name
  }
}

# Workers join through HAProxy rather than a specific server.
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
    packages       = ["qemu-guest-agent", "curl", "iptables"]
    runcmd = [
      ["systemctl", "enable", "--now", "qemu-guest-agent.service"],
      ["/usr/local/sbin/rke2-agent-sles.sh", var.rke2_agent_version],
    ]
  })}")
}

resource "harvester_virtualmachine" "bench_worker" {
  for_each   = local.rke2_worker_nodes
  depends_on = [harvester_virtualmachine.bench_lb]

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
    name           = "default"
    network_name   = "default/vm-net"
    model          = "virtio"
    type           = "bridge"
    wait_for_lease = true
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
        harvester_virtualmachine.bench_etcd,
        harvester_virtualmachine.bench,
        harvester_virtualmachine.bench_lb,
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

output "rke2_servers" {
  description = "RKE2 server roles (all, etcd or control-plane) by node name, and the bootstrap server. migrate-to-dedicated-etcd.sh and add-control-plane-server.sh resume from these roles."
  # Not updated when creating a server fails.
  depends_on = [harvester_virtualmachine.bench_bootstrap, harvester_virtualmachine.bench_etcd, harvester_virtualmachine.bench]
  value = {
    bootstrap = local.rke2_bootstrap_node
    roles     = local.rke2_server_roles
  }
}

output "haproxy_config" {
  description = "HAProxy configuration for the current API servers. Cloud-init only applies it on first boot; migrate-to-dedicated-etcd.sh and add-control-plane-server.sh push it to running load balancers."
  value       = local.haproxy_config
}
