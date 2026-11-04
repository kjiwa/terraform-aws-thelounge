mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

override_resource {
  target          = module.edge.aws_acm_certificate.this
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    domain_validation_options = [
      { domain_name = "irc.example.org", resource_record_name = "_a.irc.example.org.", resource_record_type = "CNAME", resource_record_value = "a.acm.example." },
    ]
  }
}

variables {
  domain_name = "example.org"
  zone_id     = "Z0000000000000TEST"
  alert_email = "ops@example.org"
}

run "defaults_plan_with_only_the_required_inputs" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = var.env == "prod" && var.thelounge_version == "4.5.2"
    error_message = "env and thelounge_version must default to prod and the tested release."
  }
  assert {
    condition     = length(var.thelounge_users) == 0 && var.hostname == "irc"
    error_message = "thelounge_users must default empty and hostname to irc."
  }
  assert {
    condition     = local.catchup_region == "us-east-1" && output.region == "us-east-1"
    error_message = "Regions must come from the default provider."
  }
  assert {
    condition     = length(module.status) == 0 && length(module.llm_gateway) == 0
    error_message = "The status page and catch-up gateway must be off by default."
  }
  assert {
    condition     = output.pipeline_name == "thelounge-delivery-prod" && output.asg_name == "thelounge-prod" && output.vault_name == "thelounge-backup" && output.url == "https://irc.example.org"
    error_message = "The outputs the operator scripts read must resolve at plan time."
  }
  assert {
    condition     = output.backup_mode == "local" && output.backup_role_name == "thelounge-backup" && output.backup_copy_vault_arn == null
    error_message = "A default deployment must report local backups and the backup role name."
  }
}

run "status_enabled_plans" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    status = { enabled = true }
  }

  assert {
    condition     = length(module.status) == 1
    error_message = "status.enabled must instantiate the status module."
  }
}

run "status_disabled_plans" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    status = { enabled = false }
  }

  assert {
    condition     = length(module.status) == 0
    error_message = "status.enabled = false must skip the status module."
  }
}

run "catchup_enabled_plans" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    catchup = { enabled = true }
  }

  assert {
    condition     = length(module.llm_gateway) == 1 && contains(local.plugins, "thelounge-plugin-catchup@0.6.1")
    error_message = "catchup.enabled must add the gateway and the plugin."
  }
}

run "catchup_disabled_plans" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    catchup = { enabled = false }
  }

  assert {
    condition     = length(module.llm_gateway) == 0 && length(local.plugins) == 0
    error_message = "catchup.enabled = false must add no gateway or plugin."
  }
}

run "backup_mode_local_plans" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "local" }
  }

  assert {
    condition     = output.backup_mode == "local" && output.backup_role_name == "thelounge-backup"
    error_message = "backup.mode = local must report its mode and the backup role name."
  }
}

run "backup_mode_cross_region_plans" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "cross_region" }
  }
}

run "backup_mode_cross_account_plans" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "cross_account", account_id = "000000000000" }
  }

  assert {
    condition     = local.backup_dest_reader_role_arn == "arn:aws:iam::000000000000:role/thelounge-vault-reader"
    error_message = "cross_account must construct the destination reader role ARN."
  }
  assert {
    condition     = output.backup_mode == "cross_account" && output.backup_copy_vault_arn == "arn:aws:backup:us-east-2:000000000000:backup-vault:thelounge-backup"
    error_message = "cross_account must report the backup account's destination vault ARN."
  }
}

run "backup_mode_disabled_plans" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "disabled" }
  }

  assert {
    condition     = contains(local.status_disabled_panels, "backups")
    error_message = "Disabled backups must hide the backups panel."
  }
  assert {
    condition     = output.backup_mode == "disabled" && output.backup_role_name == null
    error_message = "Disabled backups must report no backup role."
  }
}

run "rejects_invalid_alert_email" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    alert_email = "not-an-email"
  }
  expect_failures = [var.alert_email]
}

run "rejects_unknown_cpu_credits" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    cpu_credits = "burst"
  }
  expect_failures = [var.cpu_credits]
}

run "rejects_blank_rightsize_schedule" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    rightsize_schedule = " "
  }
  expect_failures = [var.rightsize_schedule]
}

run "rejects_fractional_rightsize_min_uptime" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    rightsize_min_uptime_hours = 0.5
  }
  expect_failures = [var.rightsize_min_uptime_hours]
}

run "rejects_unknown_backup_mode" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "tape" }
  }
  expect_failures = [var.backup]
}

run "rejects_cross_account_without_account_id" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "cross_account" }
  }
  expect_failures = [var.backup]
}

run "rejects_disk_alarm_out_of_range" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    disk_alarm_used_percent = 100
  }
  expect_failures = [var.disk_alarm_used_percent]
}

run "rejects_unknown_catchup_provider" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    catchup = { provider = "openai" }
  }
  expect_failures = [var.catchup]
}

run "rejects_nonpositive_catchup_window" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    catchup = { max_window_hours = 0 }
  }
  expect_failures = [var.catchup]
}

run "rejects_status_bedrock_without_catchup" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    status = { enabled = true, bedrock = true }
  }
  expect_failures = [var.status]
}
