variable "name" {
  description = "Name of the VM; also used as its hostname and as a prefix for its volumes."
  type        = string
}

variable "mac_address" {
  description = "MAC address of the VM's NIC. scripts/host-bootstrap.sh reserves a fixed DHCP address for it."
  type        = string

  validation {
    condition     = can(regex("^52:54:00(:[0-9a-f]{2}){3}$", var.mac_address))
    error_message = "mac_address must be a lowercase locally administered QEMU MAC (52:54:00:xx:xx:xx)."
  }
}

variable "vcpus" {
  description = "Number of virtual CPUs."
  type        = number
}

variable "memory_mib" {
  description = "Memory in MiB."
  type        = number
}

variable "disk_size_gib" {
  description = "Root disk size in GiB. The guest grows its root filesystem to fill it on first boot."
  type        = number

  validation {
    condition     = var.disk_size_gib >= 10
    error_message = "disk_size_gib must be at least 10 (the base image's virtual size)."
  }
}

variable "pool" {
  description = "libvirt storage pool for the VM's volumes."
  type        = string
}

variable "base_image_path" {
  description = "Absolute path of the Rocky Linux 9 GenericCloud qcow2 used as the backing file for the root disk."
  type        = string
}

variable "network" {
  description = "libvirt network the VM attaches to."
  type        = string
}

variable "ssh_user" {
  description = "Login user created by cloud-init."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key (contents, not a path) authorized for ssh_user."
  type        = string
}
