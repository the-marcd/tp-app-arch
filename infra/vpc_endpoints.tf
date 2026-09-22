# VPC endpoints giving the private subnet a path to ECR without a NAT gateway.
#
# ECR pulls need all three: the two interface endpoints for the registry API
# and the Docker registry protocol, and the S3 gateway endpoint because ECR
# stores image layers in S3.
#
# These cover private ECR only (e.g. the EKS-hosted VPC CNI image at
# 602401143452.dkr.ecr.<region>.amazonaws.com). They do NOT cover
# registry.k8s.io, public.ecr.aws, Docker Hub, or apt repositories -- see README.

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name}-vpc-endpoints"
  description = "HTTPS from the cluster nodes to interface endpoints"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-vpc-endpoints"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_from_master" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS from the control plane"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_from_workers" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS from the workers"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name}-ecr-api"
  }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name}-ecr-dkr"
  }
}

# Gateway endpoint: no ENI, no hourly charge, attaches to route tables instead.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.name}-s3"
  }
}
