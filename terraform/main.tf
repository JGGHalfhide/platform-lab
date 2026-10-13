locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# Copy-on-write root disk backed by the Rocky base image.
resource "libvirt_volume" "root" {
  name          = "${var.vm_name}-root.qcow2"
  pool          = var.pool
  capacity      = var.disk_size_gib
  capacity_unit = "GiB"

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = var.base_image_path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "seed" {
  name = "${var.vm_name}-seed"

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    ssh_user       = var.ssh_user
    ssh_public_key = local.ssh_public_key
  })

  meta_data = yamlencode({
    instance-id    = var.vm_name
    local-hostname = var.vm_name
  })
}

resource "libvirt_volume" "seed" {
  name = "${var.vm_name}-seed.iso"
  pool = var.pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.seed.path
    }
  }
}

resource "libvirt_domain" "node" {
  name        = var.vm_name
  type        = "kvm"
  vcpu        = var.vcpus
  memory      = var.memory_mib
  memory_unit = "MiB"
  running     = true

  # The 0.9 provider emits no <features> by default, which starts q35 with
  # acpi=off; the guest then can't enumerate its PCIe devices and never boots.
  features = {
    acpi = true
    apic = {}
  }

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.root.pool
            volume = libvirt_volume.root.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        driver = {
          type = "qcow2"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.seed.pool
            volume = libvirt_volume.seed.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      },
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network
          }
        }
        wait_for_ip = {
          source  = "lease"
          timeout = 300
        }
      },
    ]

    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      },
    ]
  }
}

data "libvirt_domain_interface_addresses" "node" {
  domain = libvirt_domain.node.name
  source = "lease"
}
