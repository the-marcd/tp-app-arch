# The NAT gateway is always provisioned: it bills hourly plus per-GB from the
# moment it exists, and it is what gives the private subnet its egress.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name}-nat"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${var.name}-nat"
  }

  # The NAT gateway needs a route to the internet before it can come up.
  depends_on = [aws_internet_gateway.main]
}
