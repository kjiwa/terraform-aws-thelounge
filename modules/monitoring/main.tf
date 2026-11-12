# Recorder (canary, alerts topic, episodes and Spot logs, change log) lives in
# the status-page core; backup alerts, the disk alarm and the dashboard in its
# host-alarms module.
module "availability" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/availability?ref=v0.7.0"

  name_prefix      = "thelounge"
  metric_namespace = "TheLounge"
  primary_domain   = var.primary_domain
  asg_name         = var.asg_name
  alert_email      = var.alert_email
  active           = var.active

  # Named by the sibling module rather than referenced: the alarm's actions
  # use this module's topic, so a resource reference would be a cycle.
  alarm_publishers = module.host_alarms.alarm_names
}

module "host_alarms" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/host-alarms?ref=v0.7.0"

  name_prefix                       = "thelounge"
  metric_namespace                  = "TheLounge"
  alarm_topic_arn                   = module.availability.sns_topic_arn
  episodes_log_group_name           = module.availability.episodes_log_group_name
  spot_interruptions_log_group_name = module.availability.spot_interruptions_log_group_name
  backup_enabled                    = var.backup_enabled

  # The instance publishes DiskUsedPercent every hour; twice that so a
  # drifting timer never leaves an empty bucket.
  disk_alarm_used_percent   = var.disk_alarm_used_percent
  disk_alarm_period_seconds = 7200
}
