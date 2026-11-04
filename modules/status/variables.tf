variable "primary_domain" {
  description = "Fully qualified hostname serving The Lounge. The plugin calls https://<primary_domain>/status/api with the caller's token to authenticate, so the gated routes are unusable while The Lounge is down, by design (see plugin/plugin.py). Also names the shell bucket, <primary_domain with dots as dashes>-status."
  type        = string
}

variable "distribution_arn" {
  description = "ARN of the CloudFront distribution that serves the page; allowed to read the shell bucket and invoke the Lambda."
  type        = string
}

variable "asg_name" {
  description = "Auto Scaling Group name. Looked up to find the currently running instance for the host and image panels."
  type        = string
}

variable "episodes_log_group" {
  description = "Name of the availability recorder's episodes log group (modules/monitoring)."
  type        = string
}

variable "spot_interruptions_log_group" {
  description = "Name of the availability recorder's Spot interruption log group (modules/monitoring)."
  type        = string
}

variable "spot_enabled" {
  description = "Whether the fleet runs on Spot, so the Spot panel shows before the first reclaim."
  type        = bool
}

variable "public_reliability" {
  description = "Whether /status/public serves the redacted reliability and incident history unauthenticated."
  type        = bool
}

variable "ebs_volume_id" {
  description = "EBS data volume ID read for the storage panel."
  type        = string
}

variable "bedrock" {
  description = "Bedrock model shown on the Bedrock panel (the catch-up plugin's model); null disables the panel."
  type = object({
    region   = string
    model_id = string
  })
}

variable "disabled_panels" {
  description = "Panel names the static shell hides before its first data fetch resolves (config.js)."
  type        = list(string)
}

variable "backup" {
  description = "AWS Backup facts for the backups panel, passed to the core's backup input as-is; null disables the panel and its IAM."
  type = object({
    vault_name            = string
    mode                  = string
    schedule              = string
    retention_days        = number
    resource_count        = number
    remote_retention_days = number
    region                = string
    copy_vault_arn        = string
    dest_reader_role_arn  = string
  })
}
