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

variable "public_subnet_b_cidr" {
  description = "CIDR block for the second public subnet, in a different AZ. Must sit inside var.vpc_cidr."
  type        = string
  default     = "172.31.2.0/24"
}

variable "private_subnet_b_cidr" {
  description = "CIDR block for the second private subnet, in a different AZ. Must sit inside var.vpc_cidr."
  type        = string
  default     = "172.31.3.0/24"
}

variable "public_subnet_b_az" {
  description = "Availability zone for the second public subnet. Defaults to the second AZ in the region when null."
  type        = string
  default     = null
}

variable "private_subnet_b_az" {
  description = "Availability zone for the second private subnet. Defaults to the second AZ in the region when null."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = <<-EOT
    Kubernetes cluster name, used in the kubernetes.io/cluster/<name> subnet tag
    the AWS Load Balancer Controller discovers subnets by. Must match the
    controller's --cluster-name flag. Defaults to var.name when null.
  EOT
  type        = string
  default     = null
}

variable "map_public_ip_on_launch" {
  description = "Auto-assign public IPv4 addresses to instances launched in the public subnet."
  type        = bool
  default     = true
}

variable "bastion_ssh_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to SSH to the bastion. This is the only way into the
    environment: the k8s nodes accept SSH from the bastion's security group
    alone.
  EOT
  type        = list(string)
  default     = ["47.197.109.105/32"]

  validation {
    condition     = alltrue([for c in var.bastion_ssh_cidrs : can(cidrnetmask(c))])
    error_message = "Every entry in bastion_ssh_cidrs must be a valid IPv4 CIDR, e.g. \"203.0.113.4/32\"."
  }
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
  description = <<-EOT
    Number of k8s worker nodes in the private subnet. Defaults to 0, so no
    workers are provisioned until this is set; the bastion and the control
    plane stand up without them.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.k8s_worker_count >= 0
    error_message = "k8s_worker_count cannot be negative."
  }
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

variable "bastion_public_key_path" {
  description = <<-EOT
    Path to the bastion's SSH public key file (an id_ed25519.pub or similar).
    A leading ~ is expanded. Only the public half is read: the private key is
    never handled by Terraform, so it cannot reach the state file.
  EOT
  type        = string
}

variable "k8s_public_key_path" {
  description = <<-EOT
    Path to the SSH public key file installed on every k8s_* node. A leading ~
    is expanded. Public half only, as above.
  EOT
  type        = string
}

variable "s3_bucket_name" {
  description = <<-EOT
    Name for the application S3 bucket. Leave null to derive it as
    "<name>-<account id>", since bucket names are globally unique.
  EOT
  type        = string
  default     = null
}

variable "imds_hop_limit" {
  description = <<-EOT
    IMDS PUT response hop limit. 1 keeps instance-role credentials out of reach
    of pods, whose traffic to 169.254.169.254 crosses the Flannel bridge and so
    costs an extra hop; anything needing those credentials must run
    hostNetwork: true. Raise to 2 if that proves too strict.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.imds_hop_limit >= 1 && var.imds_hop_limit <= 64
    error_message = "imds_hop_limit must be between 1 and 64."
  }
}

variable "oidc_bucket_name" {
  description = <<-EOT
    Name for the public OIDC discovery bucket used by IRSA. Leave null to derive
    it as "<name>-oidc-<account id>". This bucket is publicly readable by
    design -- AWS STS fetches the discovery document anonymously.
  EOT
  type        = string
  default     = null
}

variable "lbc_namespace" {
  description = "Namespace of the AWS Load Balancer Controller service account, for the IRSA trust policy."
  type        = string
  default     = "kube-system"
}

variable "lbc_service_account" {
  description = "Name of the AWS Load Balancer Controller service account, for the IRSA trust policy."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "ansible_repo_url" {
  description = <<-EOT
    Public git URL that cloud-init hands to ansible-pull on the control plane.
    Must be reachable unauthenticated from the private subnet via the NAT
    gateway -- ansible-pull runs before any credentials are configured.
  EOT
  type        = string
  default     = "https://github.com/the-marcd/tp-app-arch.git"
}

variable "k8smaster_playbook" {
  description = "Playbook path within the repo for ansible-pull to run on the control plane."
  type        = string
  default     = "systems/k8smaster.yml"
}

variable "dns_zone_name" {
  description = <<-EOT
    Public Route 53 hosted zone for cluster records. A subdomain zone only
    resolves once its parent delegates to it -- see the dns_zone_name_servers
    output.
  EOT
  type        = string
  default     = "tp.darcsaint.net"
}

variable "external_dns_namespace" {
  description = "Namespace of the external-dns service account, for the IRSA trust policy."
  type        = string
  default     = "kube-system"
}

variable "external_dns_service_account" {
  description = "Name of the external-dns service account, for the IRSA trust policy."
  type        = string
  default     = "external-dns"
}

variable "cert_manager_namespace" {
  description = "Namespace of the cert-manager service account, for the IRSA trust policy."
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_service_account" {
  description = "Name of the cert-manager service account, for the IRSA trust policy."
  type        = string
  default     = "cert-manager"
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Provision the NAT gateway, its Elastic IP and the private subnet's default
    route. On by default: without it the private subnet has no egress and the
    cluster cannot pull images or packages. Turn off to stop the hourly and
    per-GB charges while the environment is idle.
  EOT
  type        = bool
  default     = true
}

variable "enable_oidc_provider" {
  description = <<-EOT
    Create the cluster's IAM OIDC provider and the IRSA roles that trust it.
    Off by default: IAM validates the issuer when the provider is created, so
    this cannot succeed until the control plane has published its discovery
    documents to the OIDC bucket. Apply once with this false, let the master
    publish them, then set it true and apply again.
  EOT
  type        = bool
  default     = false
}

variable "k8snode_playbook" {
  description = "Playbook path within the repo for ansible-pull to run on the worker nodes."
  type        = string
  default     = "systems/k8snode.yml"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project   = "tp-app-arch"
    ManagedBy = "terraform"
  }
}
