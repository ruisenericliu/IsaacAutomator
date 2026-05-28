# prefix for created resources
# full name looks like <prefix>.<deployment_name>.<app_name>.<resource_type>
variable "prefix" {
  default = "isa"
  type    = string
}

variable "deployment_name" {
  type = string
}

# Nebius project ID this deployment lives under (also used as parent for
# Nebius VPC/compute resources).
variable "parent_id" {
  type = string
}

# Platform + preset are Nebius-native instance-shape selectors. They are
# split out of the AWS-style "instance type" string in deploy-nebius.
variable "platform" {
  type    = string
  default = "gpu-l40s-a"
}

variable "preset" {
  type    = string
  default = "1gpu-32vcpu-128gb"
}

# Provided for parity with the cross-cloud DeployCommand interface.
# deploy-nebius splits the combined --instance-type string and writes
# platform/preset into the tfvars; this var lets the platform-agnostic
# Deployer.create_tfvars() pass the combined string through harmlessly.
variable "isaac_workstation_instance_type" {
  type    = string
  default = ""
}

variable "from_image" {
  default = false
  type    = bool
}

# Base image family used when from_image=false.
variable "image_family" {
  type    = string
  default = "ubuntu24.04-driverless"
}

variable "ssh_port" {
  type = number
}

variable "isaac_workstation_enabled" {
  type = bool
}

variable "ingress_cidrs" {
  type = list(string)
}

variable "os_username" {
  default = "ubuntu"
  type    = string
}
