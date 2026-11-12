mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
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

run "instance_may_write_only_the_deploy_acknowledgement" {
  command = plan

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.instance.statement : s
      if contains(s.actions, "s3:PutObject")
    ]) == 1
    error_message = "Exactly one statement may grant s3:PutObject."
  }
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.instance.statement :
      s.resources == toset(["arn:aws:s3:::thelounge-delivery-123456789012/deployed/*"])
      if contains(s.actions, "s3:PutObject")
    ])
    error_message = "s3:PutObject must be scoped to exactly the bucket's deployed/* prefix."
  }
}

run "instance_may_read_the_deploy_acknowledgement_it_writes" {
  command = plan

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.instance.statement :
      contains(s.actions, "s3:GetObject") && contains(s.actions, "s3:PutObject")
      && s.resources == toset(["arn:aws:s3:::thelounge-delivery-123456789012/deployed/*"])
    ])
    error_message = "converge reads the acknowledgement to skip rewriting it, so deployed/* needs s3:GetObject beside s3:PutObject."
  }
}

run "instance_may_call_every_api_the_rightsize_check_makes" {
  command = plan

  assert {
    condition = alltrue([
      for action in [
        "autoscaling:DescribeAutoScalingGroups",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "ec2:DescribeSpotPriceHistory",
        "ec2:GetSpotPlacementScores",
      ] :
      anytrue([
        for s in data.aws_iam_policy_document.instance.statement :
        contains(s.actions, action) && s.effect == "Allow" && s.resources == toset(["*"])
      ])
    ])
    error_message = "The instance policy must allow every API scripts/keel/rightsize-check.sh calls: autoscaling:DescribeAutoScalingGroups, ec2:GetInstanceTypesFromInstanceRequirements, ec2:DescribeSpotPriceHistory, ec2:GetSpotPlacementScores."
  }
}

run "instance_env_exports_the_asg_name" {
  command = plan

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this["arm64"].user_data), "readonly ASG_NAME=\"thelounge-prod\"") && strcontains(base64decode(aws_launch_template.this["arm64"].user_data), "export ASG_NAME=$ASG_NAME")
    error_message = "user_data must export ASG_NAME (the ASG's name) through instance.env for the rightsize check."
  }
}
