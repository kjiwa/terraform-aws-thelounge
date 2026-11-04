# The paid escape hatch (var.enable_public_ipv4, default false): a default
# IPv4 route and an EIP the instance associates at boot (user_data's
# associate_eip). The internet gateway itself is unconditional (routing.tf)
# since CloudFront VPC origins require one attached regardless. Subnet-level
# map_public_ip_on_launch lives on aws_subnet.this in main.tf, since it's an
# attribute of that resource.
resource "aws_route" "ipv4_public" {
  count                  = var.enable_public_ipv4 ? 1 : 0
  route_table_id         = aws_route_table.this.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_eip" "this" {
  count  = var.enable_public_ipv4 ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "thelounge"
  }
}
