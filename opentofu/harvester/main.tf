terraform {
  required_version = ">= 1.5.0"
  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "1.9.0"
    }
  }
}

provider "harvester" {
  kubeconfig = "${path.module}/local.yaml"
}

resource "harvester_virtualmachine" "bench" {
  for_each = toset(["bench-cp-01", "bench-cp-02", "bench-cp-03"])

  name         = each.key
  namespace    = "default"
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
    network_name = "default/vm-net"
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
    auto_delete        = false
  }

  input {
    name = "tablet"
    type = "tablet"
    bus  = "usb"
  }

  cloudinit {
    type      = "noCloud"
    user_data = sensitive(file("${path.module}/cloud-config.yml"))
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "virtual_machines" {
  description = "Harvester VM IDs, runtime states, and assigned hosts."
  value = {
    for name, vm in harvester_virtualmachine.bench : name => {
      id    = vm.id
      state = vm.state
      node  = vm.node_name
    }
  }
}
