# Security headers on the client and /status/api. Not on the status page
# behaviors: the status module owns their headers. The CSP carries only
# frame-ancestors, so it cannot break the client's scripts or styles, and
# override = false lets an origin header win. HSTS omits includeSubdomains and
# preload: they bind every subdomain of the apex, which this module does not
# own. WebSocket upgrades are unaffected.
resource "aws_cloudfront_response_headers_policy" "this" {
  name    = "thelounge-security-headers"
  comment = "HSTS, nosniff, referrer policy and frame-ancestors for thelounge (${local.fqdn})."

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }

    content_type_options {
      override = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    frame_options {
      frame_option = "SAMEORIGIN"
      override     = false
    }

    content_security_policy {
      content_security_policy = "frame-ancestors 'self'"
      override                = false
    }
  }
}
