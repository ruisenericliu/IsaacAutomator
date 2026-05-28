resource "nebius_vpc_v1_security_group" "sg" {
  parent_id  = var.parent_id
  network_id = var.network_id
  name       = "${local.name_base}-sg"
}

# Security rules. `parent_id` on a security_rule is the SecurityGroup ID
# (metadata.parent_id "represents the SecurityGroup" per provider docs).
# Lower `priority` evaluates first; we space rules in increments of 10 so
# we can slot extra ALLOW/DENY rules between them later without renumbering.

resource "nebius_vpc_v1_security_rule" "ssh" {
  parent_id = nebius_vpc_v1_security_group.sg.id
  name      = "${local.name_base}-ssh"
  access    = "ALLOW"
  protocol  = "TCP"
  priority  = 100

  ingress = {
    source_cidrs      = var.ingress_cidrs
    destination_ports = [22]
  }
}

# Custom SSH port (only if non-default).
resource "nebius_vpc_v1_security_rule" "custom_ssh" {
  count     = var.ssh_port != 22 ? 1 : 0
  parent_id = nebius_vpc_v1_security_group.sg.id
  name      = "${local.name_base}-custom-ssh"
  access    = "ALLOW"
  protocol  = "TCP"
  priority  = 110

  ingress = {
    source_cidrs      = var.ingress_cidrs
    destination_ports = [var.ssh_port]
  }
}

# NoMachine uses TCP for control + UDP for video when available.
resource "nebius_vpc_v1_security_rule" "nomachine_tcp" {
  parent_id = nebius_vpc_v1_security_group.sg.id
  name      = "${local.name_base}-nomachine-tcp"
  access    = "ALLOW"
  protocol  = "TCP"
  priority  = 200

  ingress = {
    source_cidrs      = var.ingress_cidrs
    destination_ports = [4000]
  }
}

resource "nebius_vpc_v1_security_rule" "nomachine_udp" {
  parent_id = nebius_vpc_v1_security_group.sg.id
  name      = "${local.name_base}-nomachine-udp"
  access    = "ALLOW"
  protocol  = "UDP"
  priority  = 210

  ingress = {
    source_cidrs      = var.ingress_cidrs
    destination_ports = [4000]
  }
}

# VNC + noVNC (browser-side VNC access).
resource "nebius_vpc_v1_security_rule" "vnc" {
  parent_id = nebius_vpc_v1_security_group.sg.id
  name      = "${local.name_base}-vnc"
  access    = "ALLOW"
  protocol  = "TCP"
  priority  = 300

  ingress = {
    source_cidrs      = var.ingress_cidrs
    destination_ports = [5900]
  }
}

resource "nebius_vpc_v1_security_rule" "novnc" {
  parent_id = nebius_vpc_v1_security_group.sg.id
  name      = "${local.name_base}-novnc"
  access    = "ALLOW"
  protocol  = "TCP"
  priority  = 310

  ingress = {
    source_cidrs      = var.ingress_cidrs
    destination_ports = [6080]
  }
}
