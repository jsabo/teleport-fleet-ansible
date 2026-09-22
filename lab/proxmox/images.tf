# Cloud images downloaded by the Proxmox node itself into Import storage. Each VM
# disk is then created from the image over the API (`import_from`): no template VM,
# nothing uploaded from the workstation, and a destroy/apply cycle gives brand-new
# disks every time.
resource "proxmox_download_file" "image" {
  for_each = var.images

  node_name    = var.proxmox_node
  datastore_id = var.image_datastore
  content_type = "import"
  url          = each.value.url
  file_name    = each.value.file_name
  overwrite    = false
  # An interrupted apply can leave the file on the datastore without a state entry;
  # re-download it instead of failing with "file already exists".
  overwrite_unmanaged = true
}
