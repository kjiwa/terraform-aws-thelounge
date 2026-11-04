variable "env" {
  description = "Environment name (see the stack root's var.env for the full rationale)."
  type        = string
}

variable "active" {
  description = "If false the ASG holds zero instances (environment asleep). Wake by flipping to true and applying; the new instance self-deploys the last build via its converge timer."
  type        = bool
}

variable "spot_enabled" {
  description = "If true, the ASG uses Spot exclusively (see the stack root's var.spot_enabled). Defaults off here so a fresh deployment is stable and quiet until Spot is chosen deliberately -- the stack root itself defaults it on."
  type        = bool
  default     = false
}

variable "cpu_credits" {
  description = "T-instance CPU credit mode (see the stack root's var.cpu_credits for the full rationale)."
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be \"standard\" or \"unlimited\"."
  }
}

variable "instance_requirements" {
  description = "Wholesale override of the ASG instance spec (see the stack root's var.instance_requirements for the full rationale). All-or-nothing: the memory floor and per-architecture type lists must not drift apart, or a floor above a listed type's memory silently filters that type out. preferred_types spans both architectures."
  type = object({
    vcpu_min             = number
    memory_mib_min       = number
    allowed_types_arm64  = list(string)
    allowed_types_x86_64 = list(string)
    preferred_types      = list(string)
  })
  default = null
  validation {
    condition = var.instance_requirements == null ? true : (
      length(var.instance_requirements.preferred_types) > 0 &&
      alltrue([
        for t in var.instance_requirements.preferred_types :
        contains(
          concat(
            var.instance_requirements.allowed_types_arm64,
            var.instance_requirements.allowed_types_x86_64,
          ),
          t,
        )
      ])
    )
    error_message = "preferred_types must be non-empty and a subset of allowed_types_arm64 + allowed_types_x86_64. A preferred type that can never launch would make the rightsize watchdog attempt a replacement at every tick its guards allow, forever. To disable the scale-back, set preferred_types to the full allowed set."
  }
}

variable "ami_ids" {
  description = "Per-architecture AMI IDs, keyed \"arm64\" and \"x86_64\" (see the stack root's var.ami_ids for the full rationale)."
  type        = map(string)
  default     = null
  validation {
    condition     = var.ami_ids == null ? true : sort(keys(var.ami_ids)) == tolist(["arm64", "x86_64"])
    error_message = "ami_ids must be null, or contain exactly the keys \"arm64\" and \"x86_64\"."
  }
}

variable "subnet_id" {
  description = "Subnet ID for the ASG (network module)."
  type        = string
}

variable "app_sg_id" {
  description = "Security group ID for the EC2 instance (network module's thelounge-app SG)."
  type        = string
}

variable "ebs_volume_id" {
  description = "EBS data volume ID. user_data attaches it by ID at boot and finds the block device by NVMe controller serial."
  type        = string
}

variable "ebs_volume_arn" {
  description = "EBS data volume ARN. Scoped in the instance role's AttachVolume/DetachVolume statement."
  type        = string
}

variable "ebs_kms_key_arn" {
  description = "CMK ARN encrypting the data volume, or null when it uses the AWS-managed aws/ebs key (every backup mode except cross_account). See iam.tf's KMSDataVolume statement for why a non-null value is load-bearing at boot."
  type        = string
  default     = null
}

variable "config_bucket_name" {
  description = "S3 bucket name holding rendered instance config/units (config/ prefix) and built app release artifacts (artifacts/ prefix). Templated into instance.env as CONFIG_BUCKET."
  type        = string
}

variable "config_bucket_arn" {
  description = "S3 bucket ARN for config_bucket_name. Scopes the instance role's GetObject/ListBucket grants."
  type        = string
}

variable "rightsize_schedule" {
  description = "systemd OnCalendar expression for the rightsize timer (thelounge-rightsize-watchdog.timer). user_data applies it as a timer drop-in at boot, overriding the schedule shipped in the unit file; an invalid expression keeps the shipped default rather than failing the boot."
  type        = string
}

variable "rightsize_min_uptime_hours" {
  description = "Minimum instance uptime before the rightsize watchdog may force a replacement (its churn bound under aggressive schedules). Flows to the instance via instance.env."
  type        = number
}

variable "eip_allocation_id" {
  description = "Elastic IP allocation ID from the network module's enable_public_ipv4 hatch, or null when the hatch is off. Non-null makes user_data associate it with the instance at boot."
  type        = string
  default     = null
}

variable "region" {
  description = "AWS region. Templated into instance.env for on-instance aws CLI calls (with AWS_USE_DUALSTACK_ENDPOINT=true) and used to construct the instance role's AttachVolume/DetachVolume and KMS resource ARNs."
  type        = string
}

variable "llm_gateway_function_arn" {
  description = "ARN of the one Lambda the instance role may invoke (iam.tf's InvokeLlmGateway statement), or null for none."
  type        = string
  default     = null
}
