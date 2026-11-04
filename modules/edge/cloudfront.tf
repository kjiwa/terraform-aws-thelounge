locals {
  # Exactly one of each pair of dynamic origin blocks below ever renders, so
  # a single constant id per role (rather than distinguishing per origin
  # type) is enough to wire each cache behavior to the right one.
  origin_id        = "thelounge"
  status_origin_id = "thelounge-status"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  comment         = "thelounge (${local.fqdn})"

  aliases = [local.fqdn]

  # Normal path: the instance has no public IPv4 (its subnet has no IGW), so
  # CloudFront reaches it over the VPC origin's private connection instead of
  # the public internet.
  dynamic "origin" {
    for_each = var.enable_public_ipv4 ? [] : [1]
    content {
      origin_id = local.origin_id
      # Required even for a VPC origin. Not used to route traffic (the
      # vpc_origin_id below does that over the private connection); set per
      # AWS's own guidance for an EC2-backed VPC origin.
      domain_name = local.instance_private_dns

      vpc_origin_config {
        vpc_origin_id            = nonsensitive(aws_ssm_parameter.vpc_origin_chat[0].value)
        origin_read_timeout      = 60
        origin_keepalive_timeout = 60
      }
    }
  }

  # Escape hatch (var.enable_public_ipv4): route to a public EIP instead,
  # bypassing the VPC origin and repoint Lambda entirely.
  dynamic "origin" {
    for_each = var.enable_public_ipv4 ? [1] : []
    content {
      origin_id   = local.origin_id
      domain_name = var.public_origin_domain

      custom_origin_config {
        http_port                = 9000
        https_port               = 443
        origin_protocol_policy   = "http-only"
        origin_ssl_protocols     = ["TLSv1.2"]
        origin_read_timeout      = 60
        origin_keepalive_timeout = 60
      }
    }
  }

  # Status facts API origin, same instance as above, port 9001 instead of 9000 --
  # see vpc_origin.tf's aws_cloudfront_vpc_origin.status for why this is a
  # second origin rather than a second path on the first one.
  dynamic "origin" {
    for_each = var.enable_public_ipv4 ? [] : [1]
    content {
      origin_id   = local.status_origin_id
      domain_name = local.instance_private_dns

      vpc_origin_config {
        vpc_origin_id            = nonsensitive(aws_ssm_parameter.vpc_origin_status[0].value)
        origin_read_timeout      = 60
        origin_keepalive_timeout = 60
      }
    }
  }

  dynamic "origin" {
    for_each = var.enable_public_ipv4 ? [1] : []
    content {
      origin_id   = local.status_origin_id
      domain_name = var.public_origin_domain

      custom_origin_config {
        http_port                = 9001
        https_port               = 443
        origin_protocol_policy   = "http-only"
        origin_ssl_protocols     = ["TLSv1.2"]
        origin_read_timeout      = 60
        origin_keepalive_timeout = 60
      }
    }
  }

  # Status page core origins (modules/status): the shell bucket and the status
  # Lambda, reached via OAC. Function URLs are HTTPS-only, unlike the
  # plain-HTTP instance origins above.
  dynamic "origin" {
    for_each = var.status_origins
    content {
      origin_id                = origin.value.origin_id
      domain_name              = origin.value.domain_name
      origin_access_control_id = origin.value.origin_access_control_id

      dynamic "custom_origin_config" {
        for_each = origin.value.custom_origin ? [1] : []
        content {
          http_port                = 80
          https_port               = 443
          origin_protocol_policy   = "https-only"
          origin_ssl_protocols     = ["TLSv1.2"]
          origin_keepalive_timeout = 5
          origin_read_timeout      = 30
        }
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Managed policies: CachingDisabled + AllViewerExceptHostHeader. The
    # Lounge is a live socket.io app: nothing is cacheable, and the
    # WebSocket handshake needs every viewer header forwarded untouched --
    # except Host, which the origin doesn't expect (it expects the origin
    # domain_name CloudFront already sets, not the public alias).
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
  }

  # Status page core (modules/status): exact path patterns, never a wildcard.
  # First match wins, and a wildcard would match /status/public/, which the
  # Lambda's trailing-slash normalization folds into /status/public, serving
  # the public payload from an uncached behavior.
  dynamic "ordered_cache_behavior" {
    for_each = var.status_behaviors
    content {
      path_pattern             = ordered_cache_behavior.value.path_pattern
      target_origin_id         = ordered_cache_behavior.value.origin_id
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = ordered_cache_behavior.value.cache_policy_id
      origin_request_policy_id = ordered_cache_behavior.value.origin_request_policy_id

      dynamic "function_association" {
        for_each = ordered_cache_behavior.value.rewrite ? [ordered_cache_behavior.value.function_arn] : []
        content {
          event_type   = "viewer-request"
          function_arn = function_association.value
        }
      }
    }
  }

  # /status/api: the instance's own facts endpoint, which the status plugin
  # calls with the caller's Lounge token. Same two managed policies (nothing
  # here is cacheable): AllViewerExceptHostHeader is what forwards the
  # Authorization header the endpoint gates on. Exact path, placed after the
  # core behaviors; present only while the status page is.
  dynamic "ordered_cache_behavior" {
    for_each = length(var.status_behaviors) > 0 ? [1] : []
    content {
      path_pattern             = "/status/api"
      target_origin_id         = local.status_origin_id
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "thelounge"
  }
}
