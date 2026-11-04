resource "aws_security_group" "app" {
  name        = "thelounge-app"
  description = "The Lounge app instance."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "thelounge-app"
  }
}

# VPC origin traffic arrives from CloudFront's public origin-facing fleet,
# not the VPC-CIDR-local managed ENI a same-VPC-CIDR rule would expect
# (confirmed via Flow Logs: a same-CIDR rule silently REJECTed it and 504'd
# the site). Use the managed prefix list instead.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# One rule covering both ports, not two: a prefix-list-referencing rule
# counts against the account's "rules per security group" quota (60 by
# default) once per CIDR entry in the list, not once per rule --
# com.amazonaws.global.cloudfront.origin-facing currently holds 45 entries,
# so a second full rule for 9001 would need another 45 slots and blow the
# quota outright (confirmed the hard way: AuthorizeSecurityGroupIngress
# returned RulesPerSecurityGroupLimitExceeded). A single rule spanning
# 9000-9001 costs the same 45 slots as the original 9000-only rule did.
resource "aws_vpc_security_group_ingress_rule" "app_http_from_cloudfront" {
  security_group_id = aws_security_group.app.id
  description       = "The Lounge (9000/tcp) and thelounge-status (9001/tcp) from the CloudFront origin-facing fleet (VPC origin traffic)."
  ip_protocol       = "tcp"
  from_port         = 9000
  to_port           = 9001
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
}

# Break-glass SSH via the EC2 Instance Connect Endpoint (eice.tf; no SSM in
# this design).
resource "aws_vpc_security_group_ingress_rule" "app_ssh_from_eice" {
  security_group_id            = aws_security_group.app.id
  description                  = "SSH from the EC2 Instance Connect Endpoint."
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.eice.id
}

resource "aws_vpc_security_group_egress_rule" "app_all_ipv4" {
  security_group_id = aws_security_group.app.id
  description       = "All egress IPv4, for the S3 gateway endpoint and any fallback that resolves IPv4."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_all_ipv6" {
  security_group_id = aws_security_group.app.id
  description       = "All egress IPv6: IRC networks and the dual-stack EC2 API endpoint."
  ip_protocol       = "-1"
  cidr_ipv6         = "::/0"
}

resource "aws_security_group" "eice" {
  name        = "thelounge-eice"
  description = "EC2 Instance Connect Endpoint."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "thelounge-eice"
  }
}

resource "aws_vpc_security_group_egress_rule" "eice_ssh_to_app" {
  security_group_id            = aws_security_group.eice.id
  description                  = "SSH to the app instance."
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.app.id
}
