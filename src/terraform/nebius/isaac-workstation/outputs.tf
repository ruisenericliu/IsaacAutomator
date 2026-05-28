output "vm_id" {
  value = nebius_compute_v1_instance.instance.id
}

# Effective public IPv4 address assigned to the instance's primary NIC.
output "public_ip" {
  value = nebius_compute_v1_instance.instance.status.network_interfaces[0].public_ip_address.address
}
