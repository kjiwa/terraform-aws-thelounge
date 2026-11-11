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
