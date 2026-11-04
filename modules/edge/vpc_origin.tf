data "aws_caller_identity" "current" {}

# Instance lookup only runs while active: the ASG is scaled to zero while
# asleep, so there is nothing to find, and skipping the call keeps the
# locals below from ever indexing into a result that was never fetched.
data "aws_instances" "thelounge" {
  count = var.active && !var.enable_public_ipv4 ? 1 : 0

  instance_tags = {
    Project = "thelounge"
  }

  instance_state_names = ["running"]
}

locals {
  # try() covers both cases where there's no real instance to target yet:
  # asleep (the data source above has count = 0) and active but the ASG
  # hasn't launched an instance (data source ran, ids came back empty).
  instance_id = try(data.aws_instances.thelounge[0].ids[0], null)
}

# Separate from aws_instances above because the plural data source only
# exposes ids/private_ips/public_ips, not the private DNS hostname the
# distribution's origin domain_name needs below.
data "aws_instance" "thelounge" {
  count = local.instance_id != null ? 1 : 0

  instance_id = local.instance_id
}

locals {
  # Fallbacks for the same "no real instance yet" cases try() absorbs above:
  # syntactically valid values pointing at nothing real. Harmless because in
  # both cases there is also no real instance for the VPC origin's ENI to
  # route to, so the distribution isn't serving traffic through it regardless
  # of what these fields say. Once a real instance exists, the repoint Lambda
  # (repoint_lambda.tf) corrects the VPC origin's target ARN out of band; the
  # lifecycle block below then stops Terraform from fighting that update on
  # later plans.
  instance_arn = (
    local.instance_id != null
    ? "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${local.instance_id}"
    : "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/i-000000000000000000"
  )
  instance_private_dns = try(data.aws_instance.thelounge[0].private_dns, "unset.invalid")
}

# VPC origins carry no hourly charge, so this exists whenever the escape
# hatch is off -- including while asleep -- rather than being destroyed and
# recreated (losing the id the repoint Lambda and EventBridge rule target)
# on every sleep/wake cycle.
resource "aws_cloudfront_vpc_origin" "this" {
  count = var.enable_public_ipv4 ? 0 : 1

  vpc_origin_endpoint_config {
    name                   = "thelounge-${var.vpc_origin_generation}"
    arn                    = local.instance_arn
    http_port              = 9000
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  # The repoint Lambda owns the target ARN after creation (lambda/repoint.py).
  # A sleeping env's stale ARN is harmless -- nothing serves traffic through
  # it until the env wakes and the Lambda's next reconcile fixes it.
  lifecycle {
    ignore_changes = [vpc_origin_endpoint_config[0].arn]

    # CloudFront refuses DeleteVpcOrigin while any distribution still
    # references it, so a destroy-then-create replacement always fails
    # outright. create_before_destroy stands up the replacement and repoints
    # the distribution to it before the old one is torn down.
    create_before_destroy = true
  }

  tags = {
    Name = "thelounge-vpc-origin"
  }
}

# Second origin, same instance, different port: the status facts API
# (thelounge-status.py, build/app/instance/) listens on 9001, separately from
# The Lounge itself on 9000, because there is no reverse proxy in this stack
# to split one origin into two paths -- see cloudfront.tf's /status/api
# ordered_cache_behavior. A second VpcOriginEndpointConfig against the same
# instance ARN is exactly what an ALB with two listeners would otherwise be
# for; VPC origins support this directly, at no extra hourly cost.
#
# repoint.py owns this origin's target ARN the same way it owns the one
# above, and treats a failure here as non-fatal to the chat repoint -- see
# that Lambda's module docstring for the quota reasoning behind that split.
resource "aws_cloudfront_vpc_origin" "status" {
  count = var.enable_public_ipv4 ? 0 : 1

  vpc_origin_endpoint_config {
    name                   = "thelounge-status-${var.vpc_origin_generation}"
    arn                    = local.instance_arn
    http_port              = 9001
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  lifecycle {
    ignore_changes        = [vpc_origin_endpoint_config[0].arn]
    create_before_destroy = true
  }

  tags = {
    Name = "thelounge-status-vpc-origin"
  }
}

# The repoint Lambda (lambda/repoint.py) moves each distribution origin to a
# new VPC origin out of band and publishes the live id here; the distribution
# reads these, so Terraform never reverts a repoint. The VPC origins above
# only supply the initial value.
resource "aws_ssm_parameter" "vpc_origin_chat" {
  count = var.enable_public_ipv4 ? 0 : 1

  name  = "/thelounge/edge/vpc-origin/chat"
  type  = "String"
  value = aws_cloudfront_vpc_origin.this[0].id

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "vpc_origin_status" {
  count = var.enable_public_ipv4 ? 0 : 1

  name  = "/thelounge/edge/vpc-origin/status"
  type  = "String"
  value = aws_cloudfront_vpc_origin.status[0].id

  lifecycle {
    ignore_changes = [value]
  }
}
