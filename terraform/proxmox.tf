# NOTE: block/attribute names below were verified live against the
# bpg/proxmox provider's docs, not pulled from memory — but its schema has
# genuinely shifted across versions before. `tofu validate` (or the
# terraform-plan.yml CI check) will tell you fast if your pinned version
# disagrees with anything here.
#
# proxmox_download_file, not proxmox_virtual_environment_download_file: the
# latter is deprecated and goes away in the provider's v1.0. Renaming was
# free here because enable_proxy defaults to false, so these resources have
# never been applied and there's no state address to move.

resource "proxmox_download_file" "proxy_cloud_image" {
  count = var.enable_proxy ? 1 : 0

  content_type = "import"
  datastore_id = var.proxmox_file_storage_pool
  node_name    = var.proxmox_node
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "proxy" {
  count = var.enable_proxy ? 1 : 0

  name      = var.proxy_vm_name
  node_name = var.proxmox_node
  vm_id     = var.proxy_vm_id

  agent {
    enabled = true
  }

  cpu {
    cores = var.proxy_cores
  }

  memory {
    dedicated = var.proxy_memory_mb
  }

  disk {
    datastore_id = var.proxmox_storage_pool
    import_from  = proxmox_download_file.proxy_cloud_image[0].id
    interface    = "scsi0"
    size         = var.proxy_disk_gb
  }

  network_device {
    bridge = var.proxmox_network_bridge
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = var.ssh_user
      keys     = [var.ssh_public_key]
    }
  }
}
