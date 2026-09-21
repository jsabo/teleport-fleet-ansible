variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API URL, e.g. https://10.0.0.5:8006/"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Format: <user>@pve!<tokenid>=<uuid>. Needs VM create/destroy plus Sys.AccessNetwork on the node for image downloads."
}

variable "proxmox_node" {
  type    = string
  default = "proxmox"
}

variable "image_datastore" {
  type        = string
  default     = "local"
  description = "Directory datastore with the Import content type enabled; cloud images are downloaded here."
}

variable "vm_datastore" {
  type        = string
  default     = "local-lvm"
  description = "Datastore for VM disks and cloud-init drives."
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "nameservers" {
  type    = list(string)
  default = ["192.168.1.1"]
}

variable "subnet_prefix_length" {
  type    = number
  default = 24
}

variable "ssh_public_key" {
  type        = string
  description = "Public key installed for the cloud-init user on every VM."
}

variable "ci_user" {
  type        = string
  default     = "ansible"
  description = "cloud-init user on every VM (same name on Ubuntu and Rocky, so one ansible_user and one Teleport login)."
}

# Cloud images. Both are qcow2 already; Proxmox Import storage needs the .qcow2
# suffix and refuses compressed files, so the Ubuntu .img is stored under a
# .qcow2 name.
variable "images" {
  type = map(object({
    url       = string
    file_name = string
  }))
  default = {
    ubuntu-24-04 = {
      url       = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
      file_name = "noble-server-cloudimg-amd64.qcow2"
    }
    rocky-9 = {
      url       = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
      file_name = "Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
    }
  }
}

# The fleet. `family` feeds the Ansible inventory group (debian_family / rhel_family).
variable "nodes" {
  type = map(object({
    vm_id     = number
    ip        = string
    image     = string
    family    = string
    cores     = optional(number, 2)
    memory_mb = optional(number, 2048)
    disk_gb   = optional(number, 20)
  }))
  default = {
    fleet-ubuntu-1 = { vm_id = 400, ip = "192.168.1.40", image = "ubuntu-24-04", family = "debian_family" }
    fleet-ubuntu-2 = { vm_id = 401, ip = "192.168.1.41", image = "ubuntu-24-04", family = "debian_family" }
    fleet-rocky-1  = { vm_id = 402, ip = "192.168.1.42", image = "rocky-9", family = "rhel_family" }
  }
}

# Optional artifact mirror VM for the air-gapped variant (up.yml -e lab_mirror=true).
variable "mirror_enabled" {
  type    = bool
  default = false
}

variable "mirror" {
  type = object({
    vm_id     = number
    ip        = string
    image     = string
    cores     = optional(number, 2)
    memory_mb = optional(number, 2048)
    disk_gb   = optional(number, 20)
  })
  default = { vm_id = 403, ip = "192.168.1.43", image = "ubuntu-24-04" }
}

variable "mirror_hostname" {
  type    = string
  default = "fleet-mirror"
}
