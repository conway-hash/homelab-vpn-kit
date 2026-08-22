provider "google" {
  project = var.project_id
  region  = var.region
}

provider "proxmox" {
  # Built from proxmox_host + tailnet_base_domain rather than taken as a
  # whole URL, so the base domain has exactly one authoritative declaration
  # (ansible/group_vars/all/vars.yml) instead of a second copy pasted into a
  # GitHub Actions variable — which is how a doubled "ts.ts." subdomain got
  # into SETUP.md's copy-paste block in the first place.
  endpoint = "https://${var.proxmox_host}.${var.tailnet_base_domain}:8006/"
  # Terraform configures a provider whose resources appear in the config even
  # when every one of them is counted out to zero, and bpg/proxmox hard-fails
  # at configure time with no credentials at all. So a GCP-only bootstrap
  # (enable_proxy = false, no Proxmox token minted yet) needs something
  # syntactically valid here. Nothing ever authenticates with it — there are
  # no Proxmox resources to act on in that state.
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : "bootstrap@pam!unused=00000000-0000-0000-0000-000000000000"

  # PVE's own web UI cert is self-signed — the exact problem the reverse
  # proxy server fixes for humans. OpenTofu talks to the Proxmox API
  # directly here, before that server exists to front anything, so this is
  # a one-time, unavoidable exception rather than an oversight.
  insecure = true

  # Found by actually running this, not in any doc up front: Proxmox has no
  # HTTP API endpoint for uploading "snippets" content (what proxy_cloud_init
  # needs) — the provider's only option is SSH straight to the node, and
  # without this block it tries to auto-detect the node's address and gets
  # Proxmox's LAN IP, which the tailnet-only CI runner can't reach. Pointed
  # explicitly at the same tailnet address the HTTPS API already uses.
  # Reuses the SSH keypair already shared between the GCP box and this VM's
  # own cloud-init user_account — one keypair, not a third one for this.
  ssh {
    username    = "root"
    private_key = var.ssh_private_key

    node {
      name    = var.proxmox_node
      address = "${var.proxmox_host}.${var.tailnet_base_domain}"
    }
  }
}
