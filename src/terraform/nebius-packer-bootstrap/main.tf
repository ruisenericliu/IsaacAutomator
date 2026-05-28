terraform {
  required_version = ">= 1.3.5"
  backend "local" {}
  required_providers {
    nebius = {
      source  = "nebius/nebius"
      version = "~> 0.6.8"
    }
  }
}

provider "nebius" {
  service_account = {
    account_id_env       = "NB_SA_ID"
    public_key_id_env    = "NB_AUTHKEY_PUBLIC_ID"
    private_key_file_env = "NB_AUTHKEY_PRIVATE_PATH"
  }
}

# One-shot VPC + subnet + security-group that the Packer build VM attaches
# to. image-nebius applies this, harvests the subnet_id into
# NB_BUILDER_SUBNET_ID, runs `packer build`, then destroys this stack.

resource "nebius_vpc_v1_network" "net" {
  parent_id = var.parent_id
  name      = "isaac-automator-packer-net"
}

resource "nebius_vpc_v1_subnet" "subnet" {
  parent_id  = var.parent_id
  network_id = nebius_vpc_v1_network.net.id
  name       = "isaac-automator-packer-subnet"
}

resource "nebius_vpc_v1_security_group" "sg" {
  parent_id  = var.parent_id
  network_id = nebius_vpc_v1_network.net.id
  name       = "isaac-automator-packer-sg"
}

# Ephemeral Packer-build VM — open SSH from anywhere. The stack is torn
# down after `packer build` completes.
resource "nebius_vpc_v1_security_rule" "ssh" {
  parent_id = nebius_vpc_v1_security_group.sg.id
  name      = "isaac-automator-packer-ssh"
  access    = "ALLOW"
  protocol  = "TCP"
  priority  = 100

  ingress = {
    source_cidrs      = ["0.0.0.0/0"]
    destination_ports = [22]
  }
}
