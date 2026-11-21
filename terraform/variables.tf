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

variable "mac_address" {
  description = "MAC address of the VM's NIC. scripts/host-bootstrap.sh reserves a fixed DHCP address for it; the Makefile passes the same value to both (NODE_MAC)."
  type        = string
  default     = "52:54:00:70:6c:01"

  validation {
    condition     = can(regex("^52:54:00(:[0-9a-f]{2}){3}$", var.mac_address))
    error_message = "mac_address must be a lowercase locally administered QEMU MAC (52:54:00:xx:xx:xx)."
  }
}

variable "vcpus" {
  description = "Number of virtual CPUs (8 for llama.cpp inference, local-airgap-LLM docs/resource-plan.md)."
  type        = number
  default     = 8
}

variable "memory_mib" {
  description = "Memory in MiB."
  type        = number
  default     = 12288
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
  description = "Path to the SSH public key installed for ssh_user via cloud-init. ECDSA P-384, since FIPS mode rejects ed25519."
  type        = string
  default     = "~/.ssh/platform-lab_ecdsa.pub"
}

variable "airgap_rehearsal" {
  description = "Create the airgap rehearsal VM (a stand-in for the iMac target)."
  type        = bool
  default     = false
}

variable "rehearsal_vm_name" {
  description = "Name and hostname of the airgap rehearsal VM."
  type        = string
  default     = "airgap-rehearsal"
}

variable "rehearsal_mac_address" {
  description = "MAC address of the rehearsal VM's NIC; scripts/host-bootstrap.sh reserves its DHCP address (REHEARSAL_MAC in the Makefile)."
  type        = string
  default     = "52:54:00:70:6c:02"
}

variable "rehearsal_vcpus" {
  description = "Virtual CPUs for the rehearsal VM (the airgap target for local-airgap-LLM)."
  type        = number
  default     = 8
}

variable "rehearsal_memory_mib" {
  description = "Memory in MiB for the rehearsal VM; sized for the platform plus a ~5 GiB inference pod (local-airgap-LLM docs/resource-plan.md)."
  type        = number
  default     = 12288
}

variable "rehearsal_disk_size_gib" {
  description = "Root disk size in GiB for the rehearsal VM (thin qcow2)."
  type        = number
  default     = 60
}
