variable "az" {
  description = "Availability zone for the subnet. Null derives the first available AZ in the region from data.aws_availability_zones (state \"available\")."
  type        = string
  default     = null
}

variable "enable_public_ipv4" {
  description = "Provision the paid IPv4 escape hatch: an internet gateway, a 0.0.0.0/0 route, map_public_ip_on_launch on the subnet, and an Elastic IP that the instance associates at boot. False by default: the zero-IPv4 doctrine routes outbound over IPv6 (egress-only internet gateway) and to S3 via the gateway endpoint, and inbound comes only from CloudFront VPC-origin ENIs and the EC2 Instance Connect Endpoint, both in this subnet."
  type        = bool
  default     = false
}
