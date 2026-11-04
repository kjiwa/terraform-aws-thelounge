variable "domain_name" {
  description = "Apex domain the CloudFront alias is issued under (e.g. example.org). Combined with hostname as \"$${hostname}.$${domain_name}\"."
  type        = string
}

variable "hostname" {
  description = "DNS label for the IRC client, prepended to domain_name."
  type        = string
  default     = "irc"
}

variable "zone_id" {
  description = "Route53 hosted zone ID to write the ACM validation and A/AAAA alias records into."
  type        = string
}

variable "active" {
  description = "Whether the environment is awake. When false, the instance ASG is scaled to zero, so the VPC origin's instance lookup is skipped entirely rather than run against an empty ASG, and the repoint Lambda's schedule is disabled."
  type        = bool
}

variable "region" {
  description = "AWS region the instance and VPC origin live in. Used to build the instance ARN (arn:aws:ec2:<region>:<account>:instance/<id>) from the instance ID returned by the aws_instances lookup."
  type        = string
}

variable "enable_public_ipv4" {
  description = "Escape hatch: serve the origin over a public IPv4 address (public_origin_domain) via a standard custom_origin_config instead of a VPC origin. When true, the VPC origin and repoint Lambda are not created."
  type        = bool
  default     = false
}

variable "public_origin_domain" {
  description = "Public DNS name of the EC2 instance's EIP (from the network module). Required, and used as the distribution's origin, only when enable_public_ipv4 is true."
  type        = string
  default     = null
}

variable "vpc_origin_generation" {
  description = "Suffixes the VPC origin's name, which CloudFront requires to be unique per account (see the lifecycle block in vpc_origin.tf for why a name change is what forces a clean replacement). Bump to force one."
  type        = number
  default     = 3
}

variable "status_origins" {
  description = "Origins of the status page (modules/status origins output). An origin with custom_origin gets an HTTPS-only custom origin config, since Function URLs are HTTPS-only."
  type = list(object({
    origin_id                = string
    domain_name              = string
    origin_access_control_id = string
    custom_origin            = bool
  }))
  default = []
}

variable "status_behaviors" {
  description = "Ordered cache behaviors of the status page (modules/status behaviors output). Each serves GET, HEAD and OPTIONS over HTTPS, compressed; function_arn attaches a viewer-request function when rewrite is true. Exact path patterns, never a wildcard: first match wins."
  type = list(object({
    path_pattern             = string
    origin_id                = string
    cache_policy_id          = string
    origin_request_policy_id = string
    function_arn             = string
    rewrite                  = bool
  }))
  default = []
}
