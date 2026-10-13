locals {
  vm_ip = one(flatten([
    for iface in data.libvirt_domain_interface_addresses.node.interfaces : [
      for a in iface.addrs : a.addr if a.type == "ipv4"
    ]
  ]))
}

output "vm_ip" {
  description = "IPv4 address of the VM from the libvirt DHCP lease."
  value       = local.vm_ip
}

output "ssh_command" {
  description = "SSH command for the VM."
  value       = "ssh ${var.ssh_user}@${local.vm_ip}"
}
