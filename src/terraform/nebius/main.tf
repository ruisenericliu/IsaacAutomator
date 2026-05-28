terraform {
  required_version = ">= 1.3.5"
  backend "local" {}
  required_providers {
    nebius = {
      source  = "nebius/nebius"
      version = "~> 0.6.8"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Credentials are provided via the NB_SA_ID / NB_AUTHKEY_PUBLIC_ID /
# NB_AUTHKEY_PRIVATE_PATH env vars, forwarded by ./run and exported by
# src/python/nebius.py:nebius_validate_credentials().
provider "nebius" {
  service_account = {
    account_id_env       = "NB_SA_ID"
    public_key_id_env    = "NB_AUTHKEY_PUBLIC_ID"
    private_key_file_env = "NB_AUTHKEY_PRIVATE_PATH"
  }
}

module "common" {
  source = "./common"
  prefix = "${var.prefix}.${var.deployment_name}"
}

module "vpc" {
  source    = "./vpc"
  prefix    = "${var.prefix}.${var.deployment_name}"
  parent_id = var.parent_id
}

module "isaac_workstation" {
  source                = "./isaac-workstation"
  prefix                = "${var.prefix}.${var.deployment_name}.isaac-workstation"
  count                 = var.isaac_workstation_enabled ? 1 : 0
  platform              = var.platform
  preset                = var.preset
  parent_id             = var.parent_id
  from_image            = var.from_image
  image_family          = var.image_family
  prebuilt_image_family = "isaacworkstation"
  ssh_port              = var.ssh_port
  os_username           = var.os_username
  ssh_public_key        = module.common.ssh_public_key
  deployment_name       = var.deployment_name
  ingress_cidrs         = var.ingress_cidrs

  network_id = module.vpc.network_id
  subnet_id  = module.vpc.subnet_id
}
