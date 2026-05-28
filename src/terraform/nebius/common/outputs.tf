output "ssh_key" {
  value     = tls_private_key.ssh_key
  sensitive = true
}

output "ssh_public_key" {
  value = tls_private_key.ssh_key.public_key_openssh
}
