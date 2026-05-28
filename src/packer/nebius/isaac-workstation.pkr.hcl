packer {
  required_plugins {
    nebius = {
      source  = "github.com/nebius/nebius"
      version = "~> 0.0.6"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1"
    }
  }
}

# Vars can be set from environment or the command line.

variable "version" {
  default = env("VERSION")

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+(\\-[a-z0-9\\-]+)?$", var.version))
    error_message = <<EOF
Invalid version. To fix this:
  - Set VERSION environment variable.
  - Add -var=version=... argument.
EOF
  }
}

variable "nebius_parent_id" {
  default = env("NB_PARENT_ID")

  validation {
    condition     = length(var.nebius_parent_id) > 0
    error_message = <<EOF
Required variable "nebius_parent_id" is not set. To fix this:
  - Set NB_PARENT_ID environment variable.
  - Add -var=nebius_parent_id=... argument.
EOF
  }
}

# Subnet the build VM attaches to. The image-nebius wrapper provisions a
# single-subnet bootstrap VPC via src/terraform/nebius-packer-bootstrap/
# and writes the ID into NB_BUILDER_SUBNET_ID.
variable "nebius_subnet_id" {
  default = env("NB_BUILDER_SUBNET_ID")

  validation {
    condition     = length(var.nebius_subnet_id) > 0
    error_message = <<EOF
Required variable "nebius_subnet_id" is not set. To fix this:
  - Set NB_BUILDER_SUBNET_ID environment variable (image-nebius does this for you).
  - Add -var=nebius_subnet_id=... argument.
EOF
  }
}

# Service-account credentials — same trio that drives the Terraform
# provider. The Packer plugin does NOT auto-read NB_* env vars, so they
# are surfaced as explicit variables here and wired into `service_account`.
variable "nebius_sa_id" {
  default = env("NB_SA_ID")
}

variable "nebius_authkey_public_id" {
  default = env("NB_AUTHKEY_PUBLIC_ID")
}

variable "nebius_authkey_private_path" {
  default = env("NB_AUTHKEY_PRIVATE_PATH")
}

variable "platform" {
  default = "gpu-l40s-a"
}

variable "preset" {
  default = "1gpu-32vcpu-128gb"
}

variable "source_image_family" {
  default = "ubuntu24.04-driverless"
}

variable "image_name" {
  default = "$PREFIX-$VERSION"
}

variable "image_family" {
  default = "isaacworkstation"
}

variable "skip_tags" {
  default = "skip_in_image"
}

variable "isaacsim" {
  default = "v6.0.0-dev2"
}

variable "isaaclab" {
  default = "v3.0.0-beta"
}

variable "isaaclab_arena" {
  default = "release/0.1.1"
}

variable "vnc_password" {
  default = ""
}

variable "system_user_password" {
  default = ""
}

variable "in_china" {
  default = false
}

locals {
  # Nebius resource names follow the same constraint as DNS labels (lowercase
  # letters, digits, dashes). Normalize the rendered image name accordingly.
  raw_image_name      = replace(replace(var.image_name, "$VERSION", var.version), "$PREFIX", "isaac-automator-isaacworkstation")
  expanded_image_name = lower(replace(local.raw_image_name, ".", "-"))

  # image.version is required whenever image_family is set. We pass the
  # build's `VERSION` (e.g. "v4.0.0") with the leading "v" stripped to keep
  # it numeric-looking.
  image_version = replace(var.version, "/^v/", "")
}

# @see https://github.com/nebius/packer-plugin-nebius/blob/main/docs/builders/builder.mdx
source "nebius-image" "isaac-workstation" {
  communicator = "ssh"
  ssh_username = "ubuntu"

  service_account {
    account_id       = var.nebius_sa_id
    public_key_id    = var.nebius_authkey_public_id
    private_key_file = var.nebius_authkey_private_path
  }

  parent_id = var.nebius_parent_id

  base_image {
    family = var.source_image_family
  }

  disk {
    size_gibibytes = 256
    type           = "network_ssd"
  }

  network {
    subnet_id                   = var.nebius_subnet_id
    associate_public_ip_address = true
  }

  instance {
    platform = var.platform
    preset   = var.preset
  }

  image {
    name                        = local.expanded_image_name
    image_family                = var.image_family
    version                     = local.image_version
    image_family_human_readable = "Isaac Automator Workstation"
    cpu_architecture            = "amd64"
  }
}

build {
  sources = ["source.nebius-image.isaac-workstation"]

  provisioner "ansible" {
    use_proxy     = false
    groups        = ["isaac-workstation"]
    playbook_file = "/app/src/ansible/isaac-workstation.yaml"
    ansible_env_vars = [
      "ANSIBLE_CONFIG=/app/src/ansible/ansible.cfg"
    ]
    extra_arguments = [
      "--skip-tags", "${var.skip_tags}",
      "--extra-vars", "cloud='nebius' deployment_name='nebius_image' isaacsim_git_checkpoint='${var.isaacsim}' isaaclab_git_checkpoint='${var.isaaclab}' isaaclab_arena_git_checkpoint='${var.isaaclab_arena}' vnc_password='${var.vnc_password}' system_user_password='${var.system_user_password}' in_china=${var.in_china} uploads_dir='/home/ubuntu/uploads' results_dir='/home/ubuntu/results' workspace_dir='/home/ubuntu/workspace'"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo rm -rf /tmp/* /var/tmp/*",
      "sudo journalctl --vacuum-size=10M",
      "sudo dd if=/dev/zero of=/EMPTY bs=1M || true",
      "sudo rm -f /EMPTY",
      "sync"
    ]
  }
}
