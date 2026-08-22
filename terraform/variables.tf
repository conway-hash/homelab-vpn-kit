variable "project_id" {
  description = "GCP project ID the coordination server is deployed into."
  type        = string
}

variable "region" {
  description = <<-EOT
    GCP region for the VPC/subnet. Defaults to us-central1 because GCP's
    Always Free tier only covers Compute Engine usage in us-west1,
    us-central1, or us-east1 — pick a different region and this stops being
    free.
  EOT
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the VM. Must be in the region above."
  type        = string
  default     = "us-central1-a"
}

variable "instance_name" {
  description = "Name of the Compute Engine instance."
  type        = string
  default     = "coordination-server"
}

variable "machine_type" {
  description = <<-EOT
    Compute Engine machine type. Defaults to e2-micro — the only shape
    covered by the Always Free tier (1 instance per billing account, not per
    project). e2-small/e2-medium are always billed; use those instead if
    you'd rather have real headroom than a free instance.
  EOT
  type        = string
  default     = "e2-micro"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB. Free tier covers up to 30 GB of pd-standard."
  type        = number
  default     = 30
}

variable "ssh_user" {
  description = "Linux user Ansible connects as and that owns the metadata SSH key."
  type        = string
  default     = "deploy"
}

variable "ssh_public_key" {
  description = "Public half of the SSH keypair Ansible uses to reach both VMs. Shared across GCP and Proxmox on purpose — one keypair, not two."
  type        = string
  sensitive   = true
}

variable "ssh_private_key" {
  description = <<-EOT
    Same keypair as ssh_public_key — the SSH_PRIVATE_KEY secret, not a new
    one. Only OpenTofu itself needs it (not Ansible, which writes its own
    copy to a file): the proxmox provider's ssh block uses it to reach the
    Proxmox node directly for snippet uploads (see providers.tf). Requires
    this key to also be authorized for root SSH on the Proxmox HOST itself
    — separate from it being placed inside the reverse proxy server VM's
    own cloud-init user_account, which is a different, unrelated use of
    the same key. Empty is fine while enable_proxy is false.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

# --- Proxmox / reverse proxy server VM ----------------------------------

variable "enable_proxy" {
  description = <<-EOT
    Whether to manage the Proxmox reverse proxy server VM. Defaults to false
    so a brand-new copy of this repo can bootstrap the GCP coordination
    server alone — the Proxmox API and the tailnet it lives on don't exist
    yet at that point, and the pre-auth key CI needs to join the tailnet is
    minted ON the coordination server, so the first deploy has to be able to
    run without any of it. Flip the ENABLE_PROXY repo variable to "true" once
    SETUP.md steps 9-12 are done. See SETUP.md's bootstrap-order note.
  EOT
  type        = bool
  default     = false
}

variable "tailnet_base_domain" {
  description = <<-EOT
    MagicDNS base domain for the tailnet, e.g. ts.conway-hash.com. Do not
    hand-set this in CI — every workflow reads it out of
    ansible/group_vars/all/vars.yml, which is the single authoritative
    declaration. It's an input here only because Terraform can't read that
    file itself.
  EOT
  type        = string
}

variable "proxmox_host" {
  description = <<-EOT
    The Proxmox host's own tailnet hostname — just the short name, not a
    FQDN. The API endpoint is built from this plus tailnet_base_domain
    (https://<proxmox_host>.<tailnet_base_domain>:8006/) rather than stored
    as a whole URL, so the domain can't drift from group_vars/all/vars.yml.
    Usually the same string as proxmox_node, but not necessarily — one is a
    DNS name, the other is a Proxmox cluster node name.
  EOT
  type        = string
  default     = "pve"
}

variable "headscale_server_url" {
  description = <<-EOT
    Same reasoning as tailnet_base_domain: read out of
    ansible/group_vars/all/vars.yml by CI, never hand-set. Needed here (not
    just by Ansible) because the reverse proxy server VM's cloud-init joins
    the tailnet directly at boot — see proxy_cloud_init in proxmox.tf.
  EOT
  type        = string
  default     = ""
}

variable "proxy_tailscale_authkey" {
  description = <<-EOT
    The reverse proxy server VM's own one-shot Headscale pre-auth key
    (PROXY_NODE_TS_AUTHKEY secret — see SETUP.md step 11/13, non-ephemeral,
    1h expiration). Passed to cloud-init so the VM can join the tailnet at
    boot, before anything else could reach it to do that join instead.
    Empty is fine while enable_proxy is false.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_api_token" {
  description = "Proxmox API token, format 'user@realm!tokenid=uuid'. Scope it to just what VM creation needs — see SETUP.md. Empty is fine while enable_proxy is false."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_node" {
  description = "Proxmox node name the reverse proxy server VM is created on."
  type        = string
  default     = "pve"
}

variable "proxmox_storage_pool" {
  description = "Storage ID for the reverse proxy server VM's actual disk — block/LVM-thin storage (content type 'images'), not file-based. Default matches a stock Proxmox install's local-lvm."
  type        = string
  default     = "local-lvm"
}

variable "proxmox_file_storage_pool" {
  description = <<-EOT
    Storage ID the cloud image gets downloaded to before it's imported into
    the VM's disk. Deliberately a separate variable from
    proxmox_storage_pool: Proxmox storage is typed by content — the file
    download needs a 'dir'-type storage whose content types include
    'import' (default: local), while the VM's actual disk needs
    block/LVM-thin storage (proxmox_storage_pool, default: local-lvm).
    Using one storage pool for both fails with "not a file based storage!"
    on a stock install, where local-lvm can't hold arbitrary files at all.
  EOT
  type        = string
  default     = "local"
}

variable "proxmox_network_bridge" {
  description = "Proxmox network bridge the reverse proxy server VM's NIC attaches to."
  type        = string
  default     = "vmbr0"
}

variable "proxy_vm_id" {
  description = "Proxmox VM ID for the reverse proxy server VM. Pick one that isn't already in use on this node."
  type        = number
  default     = 9000
}

variable "proxy_vm_name" {
  description = "Reverse proxy server VM name — also becomes its tailnet hostname, deliberately short (see ansible/group_vars/reverse_proxy_server/vars.yml)."
  type        = string
  default     = "proxy"
}

variable "proxy_cores" {
  description = "vCPU cores for the reverse proxy server VM. Caddy is light — intentionally small."
  type        = number
  default     = 2
}

variable "proxy_memory_mb" {
  description = "RAM in MB for the reverse proxy server VM."
  type        = number
  default     = 1024
}

variable "proxy_disk_gb" {
  description = "Disk size in GB for the reverse proxy server VM."
  type        = number
  default     = 8
}
