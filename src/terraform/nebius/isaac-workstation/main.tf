terraform {
  required_providers {
    nebius = {
      source = "nebius/nebius"
    }
  }
}

locals {
  # Resource names cannot contain dots; prefix uses dots as separators upstream.
  name_base = replace(var.prefix, ".", "-")

  # Cloud-init writes the public key onto the default `ubuntu` user. The
  # provider's instance `metadata` block is read-only, so SSH-key injection
  # has to go through user-data on Nebius.
  cloud_init = <<-EOT
#cloud-config
users:
  - name: ${var.os_username}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${trimspace(var.ssh_public_key)}
EOT
}

resource "nebius_compute_v1_instance" "instance" {
  parent_id = var.parent_id
  name      = "${local.name_base}-vm"

  resources = {
    platform = var.platform
    preset   = var.preset
  }

  boot_disk = {
    attach_mode = "READ_WRITE"
    managed_disk = {
      name = "${local.name_base}-boot"
      spec = {
        type           = "NETWORK_SSD"
        size_gibibytes = 256
        source_image_family = {
          image_family = var.from_image ? var.prebuilt_image_family : var.image_family
        }
      }
    }
  }

  network_interfaces = [
    {
      name      = "eth0"
      subnet_id = var.subnet_id
      # Private IP is auto-allocated from the subnet when allocation_id is
      # omitted; ip_address itself is required, so we pass an empty block.
      ip_address = {}
      # Public IP is auto-allocated by the instance lifecycle; static=true
      # keeps the same address across stop/start (cross-cloud parity with
      # AWS Elastic IP / GCP google_compute_address).
      public_ip_address = {
        static = true
      }
      security_groups = [
        { id = nebius_vpc_v1_security_group.sg.id },
      ]
    },
  ]

  cloud_init_user_data = local.cloud_init
}
