variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix applied to all resources."
  type        = string
  default     = "tp-app"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "172.31.0.0/22"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet. Must sit inside var.vpc_cidr."
  type        = string
  default     = "172.31.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet. Must sit inside var.vpc_cidr."
  type        = string
  default     = "172.31.1.0/24"
}

variable "public_subnet_az" {
  description = "Availability zone for the public subnet. Defaults to the first AZ in the region when null."
  type        = string
  default     = null
}

variable "private_subnet_az" {
  description = "Availability zone for the private subnet. Defaults to the first AZ in the region when null."
  type        = string
  default     = null
}

variable "map_public_ip_on_launch" {
  description = "Auto-assign public IPv4 addresses to instances launched in the public subnet."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Provision a NAT gateway (plus its Elastic IP) in the public subnet and route
    the private subnet's 0.0.0.0/0 through it. Off by default: a NAT gateway
    bills hourly plus per-GB as soon as it exists, so flip this only when the
    private subnet actually needs outbound internet access.
  EOT
  type        = bool
  default     = false
}

variable "ubuntu_version" {
  description = "Ubuntu release to look up in Canonical's AMI catalogue, e.g. \"26.04\"."
  type        = string
  default     = "26.04"
}

variable "bastion_instance_type" {
  description = <<-EOT
    Instance type for the bastion in the public subnet. Defaults to a Graviton
    (arm64) type, matching the single arm64 AMI in ec2.tf.
  EOT
  type        = string
  default     = "t4g.nano"
}

variable "bastion_root_volume_size" {
  description = "Size of the bastion's root EBS volume, in GiB."
  type        = number
  default     = 10
}

variable "k8s_master_instance_type" {
  description = <<-EOT
    Instance type for the k8s master in the private subnet. Defaults to a
    Graviton (arm64) type, matching the single arm64 AMI in ec2.tf.
  EOT
  type        = string
  default     = "t4g.medium"
}

variable "k8s_master_root_volume_size" {
  description = "Size of the k8s master's root EBS volume, in GiB."
  type        = number
  default     = 20
}

variable "k8s_worker_count" {
  description = "Number of k8s worker nodes in the private subnet."
  type        = number
  default     = 2
}

variable "k8s_worker_instance_type" {
  description = <<-EOT
    Instance type for the k8s workers. Defaults to a Graviton (arm64) type,
    matching the single arm64 AMI in ec2.tf.
  EOT
  type        = string
  default     = "t4g.small"
}

variable "k8s_worker_root_volume_size" {
  description = "Size of each k8s worker's root EBS volume, in GiB."
  type        = number
  default     = 20
}

variable "bastion_public_key" {
  description = <<-EOT
    SSH public key for the bastion, in authorized_keys format (the contents of
    an id_ed25519.pub or similar). Only the public half: the private key is
    never handled by Terraform.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+) ", var.bastion_public_key))
    error_message = "bastion_public_key must be an OpenSSH public key, e.g. \"ssh-ed25519 AAAA... comment\"."
  }
}

variable "k8s_public_key" {
  description = <<-EOT
    SSH public key installed on every k8s_* node, in authorized_keys format.
    Only the public half: the private key is never handled by Terraform.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+) ", var.k8s_public_key))
    error_message = "k8s_public_key must be an OpenSSH public key, e.g. \"ssh-ed25519 AAAA... comment\"."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project   = "tp-app-arch"
    ManagedBy = "terraform"
  }
}
