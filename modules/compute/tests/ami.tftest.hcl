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

run "unpinned_seeds_each_template_from_the_latest_release" {
  command = plan

  assert {
    condition     = aws_launch_template.this["arm64"].image_id == "ami-0123456789abcdef0" && aws_launch_template.this["x86_64"].image_id == "ami-0123456789abcdef0"
    error_message = "With ami_ids null, both templates start from the latest release."
  }

  assert {
    condition     = length(data.aws_ssm_parameter.al2023) == 2
    error_message = "Each architecture reads its AL2023 parameter when unpinned."
  }
}

run "pin_is_used_as_given_and_reads_no_parameter" {
  command = plan
  variables {
    ami_ids = { arm64 = "ami-00000000000000001", x86_64 = "ami-00000000000000002" }
  }

  assert {
    condition     = aws_launch_template.this["arm64"].image_id == "ami-00000000000000001" && aws_launch_template.this["x86_64"].image_id == "ami-00000000000000002"
    error_message = "A pin must be used as given."
  }

  assert {
    condition     = length(data.aws_ssm_parameter.al2023) == 0
    error_message = "A pin must not read the SSM parameters."
  }

  assert {
    condition     = terraform_data.image_pin.input == var.ami_ids
    error_message = "The pin must reach terraform_data.image_pin, which replaces the templates when it changes."
  }
}

run "no_pin_leaves_the_image_pin_empty" {
  command = plan

  assert {
    condition     = terraform_data.image_pin.input == null
    error_message = "An unpinned stack has no pin to track."
  }
}

run "rejects_a_pin_missing_an_architecture" {
  command = plan
  variables {
    ami_ids = { arm64 = "ami-0123456789abcdef0" }
  }

  expect_failures = [var.ami_ids]
}

run "refresh_preferences_and_template_ids_are_exposed" {
  command = plan

  assert {
    condition     = output.refresh_preferences.min_healthy_percentage == 0 && output.refresh_preferences.max_healthy_percentage == 100
    error_message = "The refresh preferences a forced refresh shares with the group replace the one instance in place."
  }

  assert {
    condition     = length(output.launch_template_ids) == 2
    error_message = "The AMI updater needs a template ID per architecture."
  }
}
