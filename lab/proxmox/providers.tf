provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  # Proxmox serves a self-signed certificate by default.
  insecure = true
}
