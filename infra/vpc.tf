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
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}
