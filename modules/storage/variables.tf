variable "az" {
  description = "Availability zone for the EBS data volume. Must match the instance AZ."
  type        = string
}

variable "data_volume_size_gb" {
  description = "EBS data volume size in GB."
  type        = number
  default     = 8
}

variable "data_volume_snapshot_id" {
  description = "Snapshot ID to create the data volume from (see the stack root's var.data_volume_snapshot_id for the full rationale)."
  type        = string
  default     = null
}

variable "backup" {
  description = "Off-site backup destination for the data volume, via one AWS Backup plan (see the stack root's var.backup for the full rationale)."
  type = object({
    mode                  = optional(string, "local")
    schedule              = optional(string, "cron(0 3 * * ? *)")
    retention_days        = optional(number, 7)
    remote_retention_days = optional(number, 0)
    account_id            = optional(string, "")
    dest_vault_name       = optional(string, "thelounge-backup")
  })
  default = {}
  validation {
    condition     = contains(["local", "cross_region", "cross_account", "disabled"], var.backup.mode)
    error_message = "backup.mode must be one of: local, cross_region, cross_account, disabled."
  }
  validation {
    condition     = var.backup.mode != "cross_account" || can(regex("^[0-9]{12}$", var.backup.account_id))
    error_message = "backup.mode = cross_account requires backup.account_id (a 12-digit AWS account ID)."
  }
}

variable "backup_region" {
  description = "Destination region for off-site backup copies (see the stack root's var.backup_region for the full rationale)."
  type        = string
  default     = "us-east-2"
}
