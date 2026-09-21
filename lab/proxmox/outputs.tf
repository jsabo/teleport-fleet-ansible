output "vms" {
  description = "Every VM with its address, role and inventory family."
  value = {
    for name, v in local.all_vms : name => {
      ip     = v.ip
      role   = v.role
      family = v.family
      vm_id  = v.vm_id
    }
  }
}
