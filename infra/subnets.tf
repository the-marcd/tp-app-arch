# Two subnets per tier, in two availability zones. The second AZ exists because
# an ALB requires subnets in at least two -- see README.
#
# The AZ-a resources keep their original short names (`public`, `private`) so
# every existing reference stays valid; the AZ-b ones are suffixed `_b`.

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.public_az
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(local.cluster_subnet_tags, {
    Name                     = "${var.name}-public-a"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_b_cidr
  availability_zone       = local.public_b_az
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(local.cluster_subnet_tags, {
    Name                     = "${var.name}-public-b"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = local.private_az
  map_public_ip_on_launch = false

  tags = merge(local.cluster_subnet_tags, {
    Name                              = "${var.name}-private-a"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_b_cidr
  availability_zone       = local.private_b_az
  map_public_ip_on_launch = false

  tags = merge(local.cluster_subnet_tags, {
    Name                              = "${var.name}-private-b"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}
