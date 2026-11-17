# One Rocky Linux 9 VM: copy-on-write root disk on the GenericCloud image,
# cloud-init seed, fixed MAC on a libvirt network.

# Copy-on-write root disk backed by the Rocky base image.
resource "libvirt_volume" "root" {
  name          = "${var.name}-root.qcow2"
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
  name = "${var.name}-seed"

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    ssh_user       = var.ssh_user
    ssh_public_key = var.ssh_public_key
  })

  meta_data = yamlencode({
    instance-id    = var.name
    local-hostname = var.name
  })
}

resource "libvirt_volume" "seed" {
  name = "${var.name}-seed.iso"
  pool = var.pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.seed.path
    }
  }
}

resource "libvirt_domain" "node" {
  name        = var.name
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
        # Fixed MAC so the DHCP reservation made by scripts/host-bootstrap.sh
        # gives the VM the same address on every rebuild.
        mac = {
          address = var.mac_address
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
