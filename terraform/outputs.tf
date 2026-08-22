output "external_ip" {
  description = "Static external IP — point your domain's DNS A record here."
  value       = google_compute_address.static_ip.address
}

output "instance_name" {
  description = "Compute Engine instance name (used as the Ansible/IAP tunnel target)."
  value       = google_compute_instance.coordination_server.name
}

output "zone" {
  description = "Zone the instance runs in (needed for the IAP tunnel)."
  value       = var.zone
}

output "proxy_vm_name" {
  description = "Reverse proxy server VM name — also its tailnet hostname, used as the Ansible deploy target. Empty while enable_proxy is false; the ansible-deploy-proxy job is skipped in that case, so nothing consumes it."
  # Explicit "" rather than one(...)'s null: the deploy workflow reads this
  # with `tofu output -raw`, which errors outright on a null value, and that
  # step runs whether or not the reverse proxy server is enabled.
  value = var.enable_proxy ? proxmox_virtual_environment_vm.proxy[0].name : ""
}
