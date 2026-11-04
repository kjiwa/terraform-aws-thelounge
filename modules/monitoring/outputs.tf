output "ops_topic_arn" {
  description = "SNS topic for operational availability alerts (DOWN/RECOVERED notices from the availability canary, attributed to a Spot reclaim when applicable). Confirm the email subscription after the first apply."
  value       = module.availability.sns_topic_arn
}

output "episodes_log_group_name" {
  description = "Log group holding the outage episodes and the change log. Read by modules/status."
  value       = module.availability.episodes_log_group_name
}

output "spot_interruptions_log_group_name" {
  description = "Log group holding raw Spot interruption warnings. Read by modules/status."
  value       = module.availability.spot_interruptions_log_group_name
}
