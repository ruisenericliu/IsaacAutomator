output "subnet_id" {
  value = nebius_vpc_v1_subnet.subnet.id
}

output "network_id" {
  value = nebius_vpc_v1_network.net.id
}

output "security_group_id" {
  value = nebius_vpc_v1_security_group.sg.id
}
