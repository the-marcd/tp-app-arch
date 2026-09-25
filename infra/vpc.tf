data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  public_az  = coalesce(var.public_subnet_az, data.aws_availability_zones.available.names[0])
  private_az = coalesce(var.private_subnet_az, data.aws_availability_zones.available.names[0])

  # Second AZ: an ALB needs subnets in at least two availability zones.
  public_b_az  = coalesce(var.public_subnet_b_az, data.aws_availability_zones.available.names[1])
  private_b_az = coalesce(var.private_subnet_b_az, data.aws_availability_zones.available.names[1])

  cluster_name = coalesce(var.cluster_name, var.name)

  # Tags the AWS Load Balancer Controller uses for subnet auto-discovery.
  cluster_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}
