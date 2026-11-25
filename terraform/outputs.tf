output "vm_ip" {
  description = "IPv4 address of the build node from the libvirt DHCP lease."
  value       = module.build_node.ip
}

output "ssh_command" {
  description = "SSH command for the build node, or null while it is shut off (one lab VM runs at a time; a null IP in the string made terraform destroy fail)."
  value       = module.build_node.ip == null ? null : "ssh ${var.ssh_user}@${module.build_node.ip}"
}

output "rehearsal_ip" {
  description = "IPv4 address of the airgap rehearsal VM, or null when airgap_rehearsal is false."
  value       = one(module.airgap_rehearsal[*].ip)
}
