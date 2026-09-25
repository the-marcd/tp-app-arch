# S3 gateway endpoint: no ENI, no hourly charge, attaches to a route table
# rather than a subnet. Keeps the private subnet's S3 traffic -- including the
# control plane writing OIDC discovery documents to the oidc bucket -- off the
# NAT gateway's per-GB billing.
#
# The ECR interface endpoints that used to live here were removed: nothing in
# this build pulls from ECR now that the pod network is Flannel, and they billed
# hourly regardless.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.name}-s3"
  }
}
