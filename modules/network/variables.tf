variable "az" {
  description = "Availability zone for the subnet. Null derives the first available AZ in the region from data.aws_availability_zones (state \"available\")."
  type        = string
  default     = null
}

variable "enable_public_ipv4" {
  description = "Provision the paid IPv4 escape hatch: an internet gateway, a 0.0.0.0/0 route, map_public_ip_on_launch on the subnet, and an Elastic IP that the instance associates at boot. False by default: the zero-IPv4 doctrine routes outbound over IPv6 (egress-only internet gateway) and to S3 via the gateway endpoint, and inbound comes only from CloudFront VPC-origin ENIs and the EC2 Instance Connect Endpoint, both in this subnet, plus tcp/113 when ident is on."
  type        = bool
  default     = false
}

variable "ident" {
  description = "Open inbound tcp/113 so IRC servers can query The Lounge's identd. Free: an internet gateway and its routes have no charge. Exposure: tcp/113 from ::/0 when servers is empty (the IPv6 default route then points at the internet gateway), or from each resolved AAAA address of servers only, over /128 routes, with ::/0 left on the egress-only gateway."
  type = object({
    enabled = optional(bool, false)
    servers = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = alltrue([for s in var.ident.servers : can(regex("^(?i:[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*)$", s))])
    error_message = "ident.servers entries must be hostnames."
  }
}
