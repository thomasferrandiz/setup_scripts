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

variable "rke2_api_endpoint" {
  description = "Stable IPv4 load balancer address forwarding TCP ports 6443 and 9345 to all RKE2 server VMs."
  type        = string
  default     = "10.113.75.205"
}

resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

resource "harvester_cloudinit_secret" "bench" {
  for_each = toset(["bench-cp-01", "bench-cp-02", "bench-cp-03"])

  name      = "${each.key}-cloudinit"
  namespace = "default"
  user_data = sensitive(templatefile("${path.module}/cloud-config.yml", {
    node_name          = each.key
    is_bootstrap       = each.key == "bench-cp-01"
    api_endpoint       = var.rke2_api_endpoint
    rke2_token         = random_password.rke2_token.result
    rke2_server_script = file("${path.module}/rke2-server-sles.sh")
  }))
}

resource "harvester_virtualmachine" "bench" {
  for_each = toset(["bench-cp-01", "bench-cp-02", "bench-cp-03"])

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

output "virtual_machines" {
  description = "Harvester VM IDs, runtime states, and assigned hosts."
  value = {
    for name, vm in harvester_virtualmachine.bench : name => {
      id         = vm.id
      state      = vm.state
      node       = vm.node_name
      ip_address = try(vm.network_interface[0].ip_address, null)
    }
  }
}
