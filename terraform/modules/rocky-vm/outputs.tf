data "libvirt_domain_interface_addresses" "node" {
  domain = libvirt_domain.node.name
  source = "lease"
}

output "ip" {
  description = "IPv4 address of the VM from the libvirt DHCP lease."
  value = one(flatten([
    for iface in data.libvirt_domain_interface_addresses.node.interfaces : [
      for a in iface.addrs : a.addr if a.type == "ipv4"
    ]
  ]))
}
