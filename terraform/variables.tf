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
  description = "Public half of the SSH keypair Ansible uses to reach both VMs. The private half never touches this repo — it lives only as the SSH_PRIVATE_KEY GitHub secret. Shared across GCP and Proxmox on purpose — one keypair, one secret, not two."
  type        = string
  sensitive   = true
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
  description = "Storage ID used for both the downloaded cloud image and the reverse proxy server VM's disk."
  type        = string
  default     = "local-lvm"
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
