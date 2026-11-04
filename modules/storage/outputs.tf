output "volume_id" {
  description = "EBS data volume ID. user-data attaches it by ID at boot."
  value       = module.data_volume.volume_id
}

output "volume_arn" {
  description = "EBS data volume ARN. Used in instance IAM policy to scope AttachVolume."
  value       = module.data_volume.volume_arn
}

output "volume_kms_key_arn" {
  description = "CMK ARN encrypting the data volume; null unless backup.mode = cross_account, which is the only mode that needs one (aws/ebs cannot be shared cross-account). The re-key procedure for a volume that predates this key (docs/cross-account-backup.md) consumes it; nothing else does."
  value       = module.data_volume.volume_kms_key_arn
}

output "vault_name" {
  description = "Local AWS Backup vault the daily plan writes to. Null when backup.mode = disabled."
  value       = module.data_volume.vault_name
}

output "backup_copy_vault_arn" {
  description = "Vault each recovery point is copied to: this account's replica vault in backup_region (cross_region) or the backup account's vault (cross_account, ARN constructed from backup.account_id + backup_region + backup.dest_vault_name). Null when backups stay local or are disabled."
  value       = module.data_volume.backup_copy_vault_arn
}

output "backup_resource_count" {
  description = "Number of resources the AWS Backup selection covers. Reported on the backups panel so the recovery-point counts there are visible arithmetic (resource_count x retention_days)."
  value       = module.data_volume.backup_resource_count
}

output "backup_remote_retention_days" {
  description = "Off-site copy retention actually applied by the plan: var.backup.remote_retention_days resolved against the '0 means same as local' fallback. The status module needs the resolved value, or the panel prints a retention that does not match copy_action.lifecycle.delete_after."
  value       = module.data_volume.backup_remote_retention_days
}

output "backup_role_name" {
  description = "Name of the AWS Backup service role in this account that on-demand backup and restore jobs run as (keel's data-volume module names it <name_prefix>-backup). Null when backup.mode = disabled."
  value       = var.backup.mode == "disabled" ? null : "${local.name_prefix}-backup"
}
