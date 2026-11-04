output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  description = "CloudFront distribution's *.cloudfront.net domain name."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = aws_cloudfront_distribution.this.arn
}

output "url" {
  description = "Public HTTPS URL for the IRC client."
  value       = "https://${local.fqdn}"
}

output "fqdn" {
  description = "Fully qualified hostname serving the IRC client."
  value       = local.fqdn
}

output "vpc_origin_id" {
  description = "ID of the CloudFront VPC origin. Null when enable_public_ipv4 is true (no VPC origin exists)."
  value       = one(aws_cloudfront_vpc_origin.this[*].id)
}
