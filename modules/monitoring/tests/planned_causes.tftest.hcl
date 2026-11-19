mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  active                  = true
  backup_enabled          = true
  disk_alarm_used_percent = 80
  primary_domain          = "irc.example.org"
  asg_name                = "thelounge"
  alert_email             = "ops@example.org"
}

run "planned_causes_name_only_what_the_instance_can_attribute" {
  command = plan

  assert {
    condition     = !contains(local.planned_causes, "rightsize") && !contains(local.planned_causes, "backup")
    error_message = "The instance writes no rightsize or backup marker, so those causes can never match and must not count as planned."
  }
}
