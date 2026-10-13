variable "libvirt_uri" {
  description = "libvirt connection URI for the build host."
  type        = string
  default     = "qemu:///system"
}

variable "pool" {
  description = "libvirt storage pool holding the base image and VM disks (created by scripts/host-bootstrap.sh)."
  type        = string
  default     = "default"
}

variable "base_image_path" {
  description = "Absolute path of the Rocky Linux 9 GenericCloud qcow2 in the pool, used as the backing file for VM disks."
  type        = string
  default     = "/var/lib/libvirt/images/Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2"
}

variable "network" {
  description = "libvirt network the VM attaches to."
  type        = string
  default     = "default"
}

variable "vm_name" {
  description = "Name of the VM; also used as its hostname and as a prefix for its volumes."
  type        = string
  default     = "build-node-01"
}

variable "vcpus" {
  description = "Number of virtual CPUs."
  type        = number
  default     = 4
}

variable "memory_mib" {
  description = "Memory in MiB."
  type        = number
  default     = 8192
}

variable "disk_size_gib" {
  description = "Root disk size in GiB. The guest grows its root filesystem to fill it on first boot."
  type        = number
  default     = 40

  validation {
    condition     = var.disk_size_gib >= 10
    error_message = "disk_size_gib must be at least 10 (the base image's virtual size)."
  }
}

variable "ssh_user" {
  description = "Default cloud-init user on the Rocky GenericCloud image."
  type        = string
  default     = "rocky"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key installed for ssh_user via cloud-init."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
