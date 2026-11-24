locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# Build cluster node (connected).
module "build_node" {
  source = "./modules/rocky-vm"

  name            = var.vm_name
  mac_address     = var.mac_address
  vcpus           = var.vcpus
  memory_mib      = var.memory_mib
  disk_size_gib   = var.disk_size_gib
  pool            = var.pool
  base_image_path = var.base_image_path
  network         = var.network
  ssh_user        = var.ssh_user
  ssh_public_key  = local.ssh_public_key
}

# Disconnected target VM. Was a stand-in for the iMac (8 GB) used to rehearse
# docs/airgap-runbook.md; since 11/21 it is the airgap target for
# local-airgap-LLM, sized for inference; since 11/23 also for local-agents
# (12 vCPU, 20 GiB, like the build node: run one at a time). Egress is blocked
# on the guest by the same step as on the iMac. Off unless airgap_rehearsal = true.
module "airgap_rehearsal" {
  source = "./modules/rocky-vm"
  count  = var.airgap_rehearsal ? 1 : 0

  name            = var.rehearsal_vm_name
  mac_address     = var.rehearsal_mac_address
  vcpus           = var.rehearsal_vcpus
  memory_mib      = var.rehearsal_memory_mib
  disk_size_gib   = var.rehearsal_disk_size_gib
  pool            = var.pool
  base_image_path = var.base_image_path
  network         = var.network
  ssh_user        = var.ssh_user
  ssh_public_key  = local.ssh_public_key
}

# The build node's resources moved into the module (11/16); no rebuild.
moved {
  from = libvirt_volume.root
  to   = module.build_node.libvirt_volume.root
}

moved {
  from = libvirt_cloudinit_disk.seed
  to   = module.build_node.libvirt_cloudinit_disk.seed
}

moved {
  from = libvirt_volume.seed
  to   = module.build_node.libvirt_volume.seed
}

moved {
  from = libvirt_domain.node
  to   = module.build_node.libvirt_domain.node
}
