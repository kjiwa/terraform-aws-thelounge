variable "env" {
  description = "Environment name, scoped into per-env resource names (IAM roles, ASG, pipeline, etc.). The delivery bucket and CodeBuild projects don't vary by env (already account-scoped), so deploy one environment per AWS account."
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "Apex domain this environment serves (e.g. example.org), combined with hostname for the CloudFront alias and ACM certificate. Its public Route53 hosted zone must already exist (zone_id)."
  type        = string
}

variable "hostname" {
  description = "DNS label for the IRC client, prepended to domain_name to form the CloudFront alias (\"$${hostname}.$${domain_name}\", e.g. irc.example.org)."
  type        = string
  default     = "irc"
}

variable "alert_email" {
  description = "Email address for operational alerts (site up/down). Confirm the SNS subscription after the first apply."
  type        = string
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "az" {
  description = "Availability zone for the instance and its EBS data volume. Null (default) uses the region's first available AZ. Pin before other changes on an existing deployment -- moving AZ later replaces both the subnet and the volume (see docs/az-move.md)."
  type        = string
  default     = null
}

variable "active" {
  description = "If false, the environment sleeps: the ASG holds zero instances, and the availability canary and alarm notifications are suspended, while all state (data volume, DNS, ACM certificate, last build) is retained. Waking (flip true, apply) self-deploys the last release via the converge timer. Deploys still require an awake environment."
  type        = bool
  default     = true
}

variable "zone_id" {
  description = "ID of the existing public Route53 hosted zone for domain_name, used for ACM validation and alias records."
  type        = string
}

variable "spot_enabled" {
  description = "If true, the ASG uses Spot exclusively: a large discount off On-Demand, at the cost of frequent reclaim outages (one a day was typical, 5-10 minutes each from reclaim until the site serves again, in the availability-episodes log) and interruption emails. Default on here (the compute module itself defaults off) since the discount is worth it for a single instance."
  type        = bool
  default     = true
}

variable "cpu_credits" {
  description = "T-instance CPU credit mode. \"standard\" caps CPU at baseline once earned credits are exhausted (no surprise charges); \"unlimited\" allows sustained bursting at extra cost."
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be \"standard\" or \"unlimited\"."
  }
}

variable "instance_requirements" {
  description = "Wholesale override of the ASG instance spec (vCPU/memory floor, per-arch allowed types). Null (default) derives a spec sized for The Lounge's idle footprint."
  type = object({
    vcpu_min             = number
    memory_mib_min       = number
    allowed_types_arm64  = list(string)
    allowed_types_x86_64 = list(string)
  })
  default = null
}

variable "ami_ids" {
  description = "Per-architecture AMI IDs, keyed \"arm64\" and \"x86_64\". Null (default) resolves both from AL2023 SSM public parameters at apply time. Pin to freeze the fleet at a specific image; changes roll out via the ASG's instance refresh. A pin that is behind the latest release warns on every plan."
  type        = map(string)
  default     = null
}

variable "rightsize_schedule" {
  description = "systemd OnCalendar expression for the rightsize watchdog's schedule (replacement when the cheapest eligible Spot pool costs at most 75% of the current type's price). Accepts a timezone suffix (e.g. \"*-*-* 17:00:00 Europe/Berlin\") to track DST. Applied via a user-data timer drop-in, so a change takes effect on the next instance replacement. Spot only."
  type        = string
  default     = "*-*-* 09:00:00 UTC"
  validation {
    condition     = trimspace(var.rightsize_schedule) != ""
    error_message = "rightsize_schedule must be a systemd OnCalendar expression (see systemd.time(7))."
  }
}

variable "rightsize_min_uptime_hours" {
  description = "Minimum instance uptime before the rightsize watchdog may force a replacement -- bounds churn under an aggressive schedule, since a failed rightsize restarts the clock on the replacement (worst case: 24/this-many replacements per day)."
  type        = number
  default     = 3
  validation {
    condition     = var.rightsize_min_uptime_hours == floor(var.rightsize_min_uptime_hours) && var.rightsize_min_uptime_hours >= 1
    error_message = "rightsize_min_uptime_hours must be a whole number of hours, at least 1."
  }
}

variable "thelounge_version" {
  description = "The Lounge npm package version the app-delivery pipeline builds. Bump and apply: the pipeline's desired-state object changes, which fires the build."
  type        = string
  default     = "4.5.2"
}

variable "thelounge_plugins" {
  description = "The Lounge plugins to install into the build, as npm package specifiers (name or name@version). Empty list (the default) ships plain upstream The Lounge."
  type        = list(string)
  default     = []
}

variable "node_version" {
  description = "Node.js version the app-delivery pipeline's build environment uses to install and run The Lounge."
  type        = string
  default     = "22.23.5"
}

variable "thelounge_config" {
  description = "Overrides for The Lounge's config.js (see https://thelounge.chat/docs/configuration), shallow-merged over this stack's required defaults (locals.thelounge_config_defaults: private mode, proxy trust, bind address, port), which it may not override. Rendered to the delivery bucket."
  type        = any
  default     = {}

  validation {
    condition     = var.thelounge_config == null || length(setintersection(keys(var.thelounge_config), ["public", "reverseProxy", "host", "port"])) == 0
    error_message = "thelounge_config must not set public, reverseProxy, host or port: this stack pins them because the security group, VPC origin and user_data depend on their values."
  }
}

variable "thelounge_users" {
  description = "Users to create, as username => bcrypt password hash (generate with `thelounge hash`, not the plaintext password). The converge script creates a user only if not already present, so existing users' networks/preferences are never overwritten. Treat the values as sensitive -- they authenticate access to this deployment."
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    condition     = alltrue([for name in nonsensitive(keys(var.thelounge_users)) : can(regex("^[A-Za-z0-9_][A-Za-z0-9_.@+-]*$", name))])
    error_message = "Usernames must start with a letter, digit or underscore and contain only letters, digits, underscores, dots, at signs, plus signs and hyphens, because each becomes a file name on the instance."
  }
}

variable "data_volume_size_gb" {
  description = "EBS data volume size in GB."
  type        = number
  default     = 8
}

variable "data_volume_snapshot_id" {
  description = "Snapshot ID to create the data volume from; null (default) creates an empty volume. For disaster rebuild only (a fresh account, or after losing the original) -- never to restore into a live deployment: this is ForceNew, so changing it on an existing volume plans a replacement that prevent_destroy then refuses. See docs/restore.md."
  type        = string
  default     = null
}

# var.backup.mode picks the destination:
#
#   local          - daily recovery points in this account/region only
#                    (the stable default).
#   cross_region   - also copies each recovery point to a vault this
#                    stack creates in backup_region. Same-account region DR.
#   cross_account  - also copies to a vault another account owns (a copy
#                    this account cannot delete). Requires account_id, a
#                    matching backup-account apply in that
#                    account, org-wide cross-account backup enabled, and
#                    (for a volume that predates the CMK) a one-time
#                    re-key. Ordered procedure: docs/cross-account-backup.md.
#                    Also covers cross_region's region DR for free, as
#                    long as backup_region differs from the module region --
#                    the destination vault ARN is built from backup_region
#                    regardless of which account owns it (backup.tf), so
#                    the copy survives losing the account AND its region.
#   disabled       - no scheduled backups.
#
# retention_days sets local retention; remote_retention_days sets the
# copies' (0 = same as local) -- local is the fast restore path, remote is
# what survives a bad month. dest_vault_name must match the backup
# account's vault name: the destination ARN is constructed from
# account_id + backup_region + this name, so a mismatch fails at copy-job
# runtime, not plan time. Only cross_account reads account_id /
# dest_vault_name. schedule is an AWS Backup cron(...)/rate(...)
# expression, evaluated in UTC.
variable "backup" {
  description = "Off-site backup destination for the EBS data volume, via one AWS Backup plan."
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
  description = "Destination region for off-site backup copies. The replica vault is created there only under cross_region. Under cross_account, must match the backup account's own region -- a mismatch fails at copy-job runtime, not plan time."
  type        = string
  default     = "us-east-2"
}

variable "disk_alarm_used_percent" {
  description = "Used-space percentage of / or the data volume above which the thelounge-disk-used alarm notifies alert_email. The data volume is a fixed size, so a full disk is an outage; The Lounge has no log size cap."
  type        = number
  default     = 80
  validation {
    condition     = var.disk_alarm_used_percent > 0 && var.disk_alarm_used_percent < 100
    error_message = "disk_alarm_used_percent must be between 0 and 100 exclusive."
  }
}

variable "enable_public_ipv4" {
  description = "Provision the paid IPv4 escape hatch: an internet gateway, a default route, and an EIP the instance associates at boot, plus a CloudFront custom origin pointed at it instead of a VPC origin. The CloudFront-to-EIP hop is plain HTTP (origin_protocol_policy http-only), so it crosses the public internet unencrypted. False by default -- the zero-IPv4 posture routes outbound over IPv6/the S3 gateway endpoint and reaches the instance via VPC origin instead."
  type        = bool
  default     = false
}

variable "catchup" {
  description = "/summarize and /ask channel catch-up (npm: thelounge-plugin-catchup); disabled adds no plugin, Lambda or IAM. The instance invokes a Bedrock-calling Lambda over IPv6, so no IPv4 is needed; version is the plugin npm version, provider is lambda only, model_id is a Bedrock model or inference profile ID, region empty uses the module's region, time_zone is an IANA name (e.g. Europe/Berlin) for /summarize day boundaries and printed times, empty uses the instance zone, max_window_hours caps how far back /summarize and /ask look (hours, > 0)."
  type = object({
    enabled          = optional(bool, false)
    version          = optional(string, "0.6.1")
    provider         = optional(string, "lambda")
    model_id         = optional(string, "us.amazon.nova-2-lite-v1:0")
    region           = optional(string, "")
    time_zone        = optional(string, "")
    max_window_hours = optional(number, 24)
  })
  default = {}

  validation {
    condition     = var.catchup.provider == "lambda"
    error_message = "catchup.provider must be \"lambda\"; the plugin's other providers need IPv4 egress this stack does not have."
  }

  validation {
    condition     = var.catchup.max_window_hours > 0
    error_message = "catchup.max_window_hours must be greater than 0."
  }
}

variable "status" {
  description = "Operational status page at /status on the chat hostname (object); off unless enabled. Signed-in Lounge users see every panel; the Lounge being down locks the gated routes. public_reliability serves redacted uptime history at /status/public, readable while chat is down. bedrock adds the catch-up model's token panel and needs catchup.enabled. The page and public history are cached at CloudFront. The account's Lambda concurrency quota is 10, so the Lambda reserves none."
  type = object({
    enabled            = optional(bool, false)
    public_reliability = optional(bool, false)
    bedrock            = optional(bool, false)
  })
  default = {}

  validation {
    condition     = !var.status.bedrock || var.catchup.enabled
    error_message = "status.bedrock requires catchup.enabled, because the panel reports the catch-up model's usage."
  }
}
