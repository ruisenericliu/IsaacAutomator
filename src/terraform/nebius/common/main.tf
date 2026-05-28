# SSH keypair. Nebius has no managed keypair primitive, so we generate the
# pair locally and inject the public key via cloud-init in isaac-workstation/.
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
