output "url" {
  description = "Public HTTPS URL for the IRC client."
  value       = module.edge.url
}

output "cloudfront_domain" {
  description = "CloudFront distribution's *.cloudfront.net domain name."
  value       = module.edge.distribution_domain_name
}

output "asg_name" {
  description = "Auto Scaling Group name."
  value       = module.compute.asg_name
}

output "delivery_bucket_arn" {
  description = "S3 delivery bucket ARN."
  value       = module.app_delivery.bucket_arn
}

output "delivery_bucket" {
  description = "S3 delivery bucket name, holding rendered instance config/units and built app release artifacts."
  value       = module.app_delivery.bucket_name
}

output "pipeline_name" {
  description = "CodePipeline name. A change to thelounge_version, node_version, or thelounge_plugins triggers it automatically; find it here to watch a run or start one manually."
  value       = module.app_delivery.pipeline_name
}

output "data_volume_id" {
  description = "EBS data volume ID."
  value       = module.storage.volume_id
}

output "vault_name" {
  description = "Local AWS Backup vault the daily plan writes to. Null when backup.mode = disabled."
  value       = module.storage.vault_name
}

output "backup_mode" {
  description = "Resolved backup.mode: local, cross_region, cross_account or disabled."
  value       = var.backup.mode
}

output "backup_role_name" {
  description = "Name of the AWS Backup service role in this account that on-demand backup and restore jobs run as. Null when backup.mode = disabled."
  value       = module.storage.backup_role_name
}

output "backup_copy_vault_arn" {
  description = "Vault each recovery point is copied to (the backup.mode = cross_region replica vault, or the backup account's vault under cross_account). Null when backups stay local or are disabled. The destination vault's name, region and account are fields of this ARN."
  value       = module.storage.backup_copy_vault_arn
}

output "instance_role_arn" {
  description = "IAM role ARN attached to EC2 instances."
  value       = module.compute.instance_role_arn
}

output "region" {
  description = "AWS region of the default provider, where the workload runs."
  value       = data.aws_region.default.region
}
