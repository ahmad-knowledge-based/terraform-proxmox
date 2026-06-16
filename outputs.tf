output "template_id" {
  description = "VMID of the VM template built by Terraform (null when cloning an existing template)"
  value       = var.template != null ? proxmox_virtual_environment_vm.template[0].vm_id : var.vm_clone_template_id
}

output "workloads" {
  description = "Map of QEMU VM name to its VMID, node, and reported IPv4 addresses (requires guest agent)"
  value = {
    for name, vm in proxmox_virtual_environment_vm.workload :
    name => {
      vm_id          = vm.vm_id
      node_name      = vm.node_name
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}

output "lxc_workloads" {
  description = "Map of LXC container name to its VMID and node"
  value = {
    for name, ct in proxmox_virtual_environment_container.workload :
    name => {
      vm_id     = ct.vm_id
      node_name = ct.node_name
    }
  }
}
