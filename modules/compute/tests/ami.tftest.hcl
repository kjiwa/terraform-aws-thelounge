mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0", insecure_value = "ami-0123456789abcdef0" }
  }
}

variables {
  env                        = "prod"
  active                     = true
  subnet_id                  = "subnet-0123456789abcdef0"
  app_sg_id                  = "sg-0123456789abcdef0"
  ebs_volume_id              = "vol-0123456789abcdef0"
  ebs_volume_arn             = "arn:aws:ec2:us-east-1:123456789012:volume/vol-0123456789abcdef0"
  config_bucket_name         = "thelounge-delivery-123456789012"
  config_bucket_arn          = "arn:aws:s3:::thelounge-delivery-123456789012"
  rightsize_schedule         = "daily"
  rightsize_min_uptime_hours = 24
  region                     = "us-east-1"
}

run "unpinned_follows_the_latest_release" {
  command = plan

  assert {
    condition     = local.ami_ids["arm64"] == "ami-0123456789abcdef0" && local.ami_ids["x86_64"] == "ami-0123456789abcdef0"
    error_message = "With ami_ids null, both architectures resolve to the latest release."
  }
}

run "current_pin_is_used_and_flags_nothing_stale" {
  command = plan
  variables {
    ami_ids = { arm64 = "ami-0123456789abcdef0", x86_64 = "ami-0123456789abcdef0" }
  }

  assert {
    condition     = local.ami_ids["arm64"] == var.ami_ids["arm64"] && local.ami_ids["x86_64"] == var.ami_ids["x86_64"]
    error_message = "A pin must be used as given."
  }

  assert {
    condition     = length(local.stale_ami_ids) == 0
    error_message = "A pin equal to the latest release must not be flagged."
  }
}

run "stale_pin_warns_on_every_plan" {
  command = plan
  variables {
    ami_ids = { arm64 = "ami-00000000000000001", x86_64 = "ami-0123456789abcdef0" }
  }

  expect_failures = [check.ami_ids_are_latest]
}

run "rejects_a_pin_missing_an_architecture" {
  command = plan
  variables {
    ami_ids = { arm64 = "ami-0123456789abcdef0" }
  }

  expect_failures = [var.ami_ids]
}
