mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
}

# for_each in acm.tf and the policy resources need these known at plan time.
override_resource {
  target          = aws_acm_certificate.this
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/mock"
    domain_validation_options = [{
      domain_name           = "irc.example.org"
      resource_record_name  = "_x.irc.example.org."
      resource_record_type  = "CNAME"
      resource_record_value = "_y.acm-validations.aws."
    }]
  }
}

override_resource {
  target          = aws_cloudfront_distribution.this
  override_during = plan
  values = {
    arn = "arn:aws:cloudfront::123456789012:distribution/EDIST"
  }
}

variables {
  domain_name = "example.org"
  zone_id     = "Z0123456789"
  active      = true
  region      = "us-east-1"
}

run "repoint_distribution_actions_are_scoped_to_the_distribution" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.repoint[0].statement :
      contains(s.actions, "cloudfront:UpdateDistribution")
      && s.resources == toset(["arn:aws:cloudfront::123456789012:distribution/EDIST"])
    ])
    error_message = "Get/UpdateDistribution must be scoped to the distribution ARN."
  }
}

run "vpc_origin_get_and_delete_are_scoped_to_vpc_origins" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.repoint[0].statement :
      contains(s.actions, "cloudfront:GetVpcOrigin") && contains(s.actions, "cloudfront:DeleteVpcOrigin")
      && s.resources == toset(["arn:aws:cloudfront::123456789012:vpcorigin/*"])
    ])
    error_message = "Get/DeleteVpcOrigin must be scoped to vpcorigin/* in the account."
  }
}

run "only_create_and_list_vpc_origins_take_a_wildcard" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.repoint[0].statement :
      s.actions == toset(["cloudfront:CreateVpcOrigin", "cloudfront:ListVpcOrigins"])
      && s.resources == toset(["*"])
    ])
    error_message = "Create/ListVpcOrigins take no resource and belong alone on *."
  }
}

run "repoint_lock_is_scoped_to_its_parameter" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.repoint[0].statement :
      s.actions == toset(["ssm:GetParameter", "ssm:PutParameter", "ssm:DeleteParameter"])
      && s.resources == toset(["arn:aws:ssm:us-east-1:123456789012:parameter/thelounge/edge/repoint-lock"])
    ])
    error_message = "Delete and Put/GetParameter on the lock must be scoped to the lock parameter."
  }
}

run "repoint_runs_on_an_instance_running_event_and_a_five_minute_poll" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = aws_cloudwatch_event_rule.repoint[0].schedule_expression == "rate(5 minutes)"
    error_message = "The schedule is the safety net and must be slower than the event."
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.repoint_instance_running[0].event_pattern).detail.state == ["running"]
    error_message = "The event rule must fire when an instance enters running."
  }

  assert {
    condition     = aws_cloudwatch_event_target.repoint_instance_running[0].arn == aws_lambda_function.repoint[0].arn
    error_message = "The event rule must invoke the repoint Lambda."
  }
}
