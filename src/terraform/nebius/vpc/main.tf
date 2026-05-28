terraform {
  required_providers {
    nebius = {
      source = "nebius/nebius"
    }
  }
}

resource "nebius_vpc_v1_network" "network" {
  parent_id = var.parent_id
  name      = replace("${var.prefix}-network", ".", "-")
}

resource "nebius_vpc_v1_subnet" "subnet" {
  parent_id  = var.parent_id
  network_id = nebius_vpc_v1_network.network.id
  name       = replace("${var.prefix}-subnet", ".", "-")
}
