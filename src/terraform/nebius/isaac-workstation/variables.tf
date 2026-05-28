variable "prefix" {
  type = string
}

variable "deployment_name" {
  type = string
}

variable "parent_id" {
  type = string
}

variable "platform" {
  type = string
}

variable "preset" {
  type = string
}

variable "from_image" {
  type = bool
}

# Base image family used when from_image=false.
variable "image_family" {
  type = string
}

# Image family produced by image-nebius / src/packer/nebius/, used when
# from_image=true.
variable "prebuilt_image_family" {
  type = string
}

variable "ssh_port" {
  type = number
}

variable "os_username" {
  type = string
}

variable "ssh_public_key" {
  type      = string
  sensitive = true
}

variable "network_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "ingress_cidrs" {
  type = list(string)
}
