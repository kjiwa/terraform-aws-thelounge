variable "active" {
  description = "If false the environment is asleep: the canary schedule and the alarm-notification rule are disabled so a deliberately-empty ASG does not page anyone. Re-enabling sends one RECOVERED notice once the site is back."
  type        = bool
}

variable "backup_enabled" {
  description = "Whether AWS Backup is running (var.backup.mode != disabled at the root). Gates the backup-failure alert rule."
  type        = bool
}

variable "disk_alarm_used_percent" {
  description = "Used-space percentage of / or the data volume at which thelounge-disk-used alarms."
  type        = number
}

variable "primary_domain" {
  description = "Fully qualified hostname serving The Lounge (e.g. irc.example.org). The availability canary GETs https://<primary_domain>/ every minute; HTTP 200 with a nonempty body counts as up."
  type        = string
}

variable "asg_name" {
  description = "Auto Scaling Group name. Used to look up the replacement instance after an outage."
  type        = string
}

variable "alert_email" {
  description = "Email address that receives DOWN/RECOVERED notices. Confirm the SNS subscription email after the first apply."
  type        = string
}
