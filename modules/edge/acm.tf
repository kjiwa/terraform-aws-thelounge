locals {
  fqdn = "${var.hostname}.${var.domain_name}"
}

# CloudFront only accepts certificates issued in us-east-1, so this pins to
# the us_east_1 provider alias rather than following this module's default
# region.
resource "aws_acm_certificate" "this" {
  provider = aws.us_east_1

  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "thelounge-${local.fqdn}"
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => dvo
  }

  zone_id         = var.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 60
  records         = [each.value.resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.this.arn
  # Built from the record RESOURCES (not domain_validation_options) so the
  # graph orders record creation before this wait.
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
