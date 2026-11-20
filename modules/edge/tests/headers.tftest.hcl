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
  target          = aws_cloudfront_response_headers_policy.this
  override_during = plan
  values = {
    id = "mock-policy-id"
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

run "every_edge_owned_behavior_carries_the_security_headers_policy" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  variables {
    status_behaviors = [{
      path_pattern             = "/status/public"
      origin_id                = "thelounge-status"
      cache_policy_id          = "658327ea-f89d-4fab-a63d-7e88639e58f6"
      origin_request_policy_id = null
      function_arn             = null
      rewrite                  = false
    }]
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].response_headers_policy_id == "mock-policy-id"
    error_message = "The default behavior must carry the security headers policy."
  }

  assert {
    condition = anytrue([
      for b in aws_cloudfront_distribution.this.ordered_cache_behavior :
      b.path_pattern == "/status/api" && b.response_headers_policy_id == "mock-policy-id"
    ])
    error_message = "/status/api must carry the security headers policy."
  }
}

run "security_headers_policy_has_the_five_headers" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition = (
      aws_cloudfront_response_headers_policy.this.security_headers_config[0].strict_transport_security[0].access_control_max_age_sec == 31536000
      && !aws_cloudfront_response_headers_policy.this.security_headers_config[0].strict_transport_security[0].include_subdomains
      && !aws_cloudfront_response_headers_policy.this.security_headers_config[0].strict_transport_security[0].preload
    )
    error_message = "HSTS must be one year, without includeSubDomains or preload."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.this.security_headers_config[0].content_type_options[0].override
    error_message = "X-Content-Type-Options nosniff must be set."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.this.security_headers_config[0].referrer_policy[0].referrer_policy == "strict-origin-when-cross-origin"
    error_message = "Referrer-Policy must be strict-origin-when-cross-origin."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.this.security_headers_config[0].frame_options[0].frame_option == "SAMEORIGIN"
    error_message = "X-Frame-Options must be SAMEORIGIN."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.this.security_headers_config[0].content_security_policy[0].content_security_policy == "frame-ancestors 'self'"
    error_message = "The CSP must be frame-ancestors 'self'."
  }
}
