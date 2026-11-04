data "archive_file" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  type        = "zip"
  source_file = "${path.module}/lambda/repoint.py"
  output_path = "${path.module}/lambda/repoint.zip"
}

resource "aws_lambda_function" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  function_name    = "thelounge-repoint"
  role             = aws_iam_role.repoint[0].arn
  runtime          = "python3.13"
  handler          = "repoint.handler"
  filename         = data.archive_file.repoint[0].output_path
  source_code_hash = data.archive_file.repoint[0].output_base64sha256
  memory_size      = 128
  # Dominated by CloudFront's own deploy times (create-VPC-origin then
  # update-distribution) -- see the budget constants in lambda/repoint.py,
  # sized to fit inside this with room to spare.
  timeout = 870

  # No reserved_concurrent_executions: the account's concurrency quota is
  # already at AWS's 10-unreserved floor, so reserving any here isn't
  # possible without a quota increase. An overlapping run (this one still
  # mid-repoint when the next tick fires) is self-limiting instead: the
  # loser's create_vpc_origin hits EntityAlreadyExists, the invocation
  # errors, and the next tick's idempotent fast path cleans it up.

  # The schedule can invoke within seconds of creation; without this the
  # runtime auto-creates the log group first and Terraform's create conflicts.
  depends_on = [aws_cloudwatch_log_group.repoint]

  environment {
    variables = {
      DISTRIBUTION_ID = aws_cloudfront_distribution.this.id
      REGION          = var.region
      ACCOUNT_ID      = data.aws_caller_identity.current.account_id
    }
  }

  tags = {
    Name = "thelounge-repoint"
  }
}

resource "aws_cloudwatch_log_group" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  name              = "/aws/lambda/thelounge-repoint"
  retention_in_days = 30

  tags = {
    Name = "thelounge-repoint"
  }
}

# --- trigger ---------------------------------------------------------------

# Reconcile on a schedule rather than react to a launch event: see the
# module docstring in lambda/repoint.py for why. Mirrors the availability
# module's canary schedule (monitoring/lambda.tf).
resource "aws_cloudwatch_event_rule" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  name                = "thelounge-repoint"
  description         = "Reconcile the CloudFront VPC origin against the running instance."
  schedule_expression = "rate(1 minute)"
  state               = var.active ? "ENABLED" : "DISABLED"

  tags = {
    Name = "thelounge-repoint"
  }
}

resource "aws_cloudwatch_event_target" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  rule      = aws_cloudwatch_event_rule.repoint[0].name
  target_id = "repoint-lambda"
  arn       = aws_lambda_function.repoint[0].arn
}

resource "aws_lambda_permission" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  statement_id  = "AllowRepointRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.repoint[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.repoint[0].arn
}

# --- IAM ---------------------------------------------------------------------

data "aws_iam_policy_document" "repoint_assume" {
  count = var.enable_public_ipv4 ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  name               = "thelounge-repoint"
  assume_role_policy = data.aws_iam_policy_document.repoint_assume[0].json

  tags = {
    Name = "thelounge-repoint"
  }
}

data "aws_iam_policy_document" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  # Resource: "*" -- this action family doesn't support resource-level
  # scoping, and the account holds one distribution/origin at a time, so
  # "*" grants nothing broader in practice.
  statement {
    sid    = "ManageVpcOrigins"
    effect = "Allow"
    actions = [
      "cloudfront:GetVpcOrigin",
      "cloudfront:ListVpcOrigins",
      "cloudfront:CreateVpcOrigin",
      "cloudfront:DeleteVpcOrigin",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "RepointDistribution"
    effect    = "Allow"
    actions   = ["cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution"]
    resources = ["*"]
  }

  # CreateVpcOrigin authorizes the caller against the origin's target as well
  # as the cloudfront:* actions above -- these are required even for an
  # EC2-instance target, not just an ALB/NLB one. Omitting them is what
  # produces a bare AccessDenied on CreateVpcOrigin with no other symptom.
  statement {
    sid    = "DescribeVpcOriginTarget"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInternetGateways",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeListeners",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "PublishVpcOriginIds"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [
      aws_ssm_parameter.vpc_origin_chat[0].arn,
      aws_ssm_parameter.vpc_origin_status[0].arn,
    ]
  }

  statement {
    sid       = "OwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.repoint[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "repoint" {
  count = var.enable_public_ipv4 ? 0 : 1

  name   = "thelounge-repoint"
  role   = aws_iam_role.repoint[0].id
  policy = data.aws_iam_policy_document.repoint[0].json
}
