variable "domain_name" {
  description = "Apex domain the site is served from (string). Point its registrar at the name servers this stack outputs."
  type        = string
}

variable "alert_email" {
  description = "Address for outage, cost, and audit alerts (string)."
  type        = string
}

variable "region" {
  description = "Region the site runs in (string). CloudFront certificates always use us-east-1."
  type        = string
  default     = "us-east-1"
}
