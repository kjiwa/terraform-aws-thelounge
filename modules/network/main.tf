# First available AZ in the region when var.az is not pinned. Filtered to
# "available" so a region with opted-out or impaired AZs never derives one
# that can't launch.
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  az = var.az != null ? var.az : data.aws_availability_zones.available.names[0]
}

resource "aws_vpc" "this" {
  cidr_block                       = "10.20.0.0/24"
  assign_generated_ipv6_cidr_block = true
  enable_dns_support               = true
  enable_dns_hostnames             = true

  tags = {
    Name = "thelounge"
  }
}

# Single subnet sized to the whole VPC: this module runs one instance in one
# AZ, so there is nothing a second subnet would isolate or a smaller IPv4
# block would save. /64 is the smallest IPv6 block AWS allocates to a subnet;
# cidrsubnet(..., 8, 0) carves the first (and only) one out of the VPC's
# amazon-provided /56.
resource "aws_subnet" "this" {
  vpc_id                          = aws_vpc.this.id
  cidr_block                      = aws_vpc.this.cidr_block
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, 0)
  availability_zone               = local.az
  assign_ipv6_address_on_creation = true
  # Only takes effect once var.enable_public_ipv4 has also put a route to an
  # internet gateway in this subnet's table (public_ipv4.tf); harmless when
  # off since there is no IPv4 path for an assigned public address to use.
  map_public_ip_on_launch = var.enable_public_ipv4

  tags = {
    Name = "thelounge"
  }
}
