# Gated on var.enable_nat_gateway, default true: the private subnet has no other
# egress, so the cluster cannot build without it. Set false to stop the hourly
# and per-GB charges while the environment is idle -- the private subnet then
# keeps only its implicit local route.
resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${var.name}-nat"
  }
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${var.name}-nat"
  }

  # The NAT gateway needs a route to the internet before it can come up.
  depends_on = [aws_internet_gateway.main]
}
