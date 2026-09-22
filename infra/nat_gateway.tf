# Everything here is gated on var.enable_nat_gateway. With the default (false)
# no NAT gateway, and no Elastic IP, is provisioned and nothing here bills.
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
