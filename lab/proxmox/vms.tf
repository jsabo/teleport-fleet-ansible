locals {
  fleet = {
    for name, n in var.nodes : name => merge(n, { role = "node" })
  }
  mirror = var.mirror_enabled ? {
    (var.mirror_hostname) = merge(var.mirror, { role = "mirror", family = "debian_family" })
  } : {}
  all_vms = merge(local.fleet, local.mirror)
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.all_vms

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  tags      = ["fleet-lab", each.value.role]

  cpu {
    cores   = each.value.cores
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  # Disk created from the downloaded cloud image, then grown to disk_gb; cloud-init
  # in the guest grows the root filesystem on first boot.
  disk {
    datastore_id = var.vm_datastore
    interface    = "virtio0"
    import_from  = proxmox_download_file.image[each.value.image].id
    size         = each.value.disk_gb
    discard      = "on"
    iothread     = true
  }

  boot_order = ["virtio0"]

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  # Proxmox renders these into the cloud-init drive: static address, DNS, one user
  # with the SSH key and passwordless sudo (cloud-init's default-user semantics).
  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.subnet_prefix_length}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.nameservers
    }

    user_account {
      username = var.ci_user
      keys     = [var.ssh_public_key]
    }
  }

  # The Ubuntu cloud image ships without qemu-guest-agent and the IPs are static,
  # so nothing waits on the agent.
  agent {
    enabled = false
  }

  serial_device {}

  vga {
    type = "serial0"
  }

  operating_system {
    type = "l26"
  }

  started         = true
  stop_on_destroy = true
}
