# IPv6-only equivalent of a NAT gateway: lets the instance initiate outbound
# IPv6 (IRC) without accepting inbound, and unlike a NAT gateway it has no
# hourly or per-GB charge. There is no IPv4 route out of this VPC unless
# var.enable_public_ipv4 turns on the paid hatch in public_ipv4.tf.
resource "aws_egress_only_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "thelounge"
  }
}

# Required marker for CloudFront VPC origins: a VPC origin is rejected unless
# an internet gateway is attached to the VPC. It carries no route (the IPv4
# default route lives in public_ipv4.tf, added only by the paid hatch) and no
# instance has a public IPv4, so nothing is reachable through it -- it only
# tells CloudFront the VPC may receive its traffic. Free to attach.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "thelounge"
  }
}

# No inline `route` blocks on this table: its IPv4 default route is
# conditional (public_ipv4.tf adds one only when the hatch is on), and mixing
# inline route blocks with standalone aws_route resources on the same table
# fights itself on every apply. So every route for this table, including the
# unconditional IPv6 one below, is a standalone aws_route resource.
resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "thelounge"
  }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

resource "aws_route" "ipv6_egress" {
  route_table_id              = aws_route_table.this.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this.id
}

# Gateway endpoint: free, and with no internet path this is the only way the
# instance reaches S3 -- config/artifacts (the converge script) and the
# S3-hosted dnf mirrors security updates pull from.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.this.id]

  tags = {
    Name = "thelounge-s3"
  }
}
