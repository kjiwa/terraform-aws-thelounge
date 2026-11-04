data "aws_caller_identity" "current" {}

locals {
  # Cross-region system profiles (us.*, global.*, ...) route to foundation
  # models in other regions, so invoking one needs the profile ARN and the
  # underlying foundation-model ARN in every region it routes to.
  profile_match = regex("^(?:([a-z][a-z-]*)\\.)?([a-z0-9-]+\\.[^.]+)$", var.model_id)
  is_profile    = local.profile_match[0] != null
  profile_arn   = local.is_profile ? "arn:aws:bedrock:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.model_id}" : null
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = {
    Name = local.name
  }
}

data "aws_iam_policy_document" "this" {
  statement {
    sid       = "OwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  # Invoking a system inference profile needs the profile ARN, plus the
  # foundation model in every region it routes to; the InferenceProfileArn
  # condition (AWS Bedrock user guide, inference profile prerequisites) lets
  # that be a region wildcard that works only through this profile.
  dynamic "statement" {
    for_each = local.is_profile ? [1] : []
    content {
      sid       = "BedrockInvokeProfile"
      effect    = "Allow"
      actions   = ["bedrock:InvokeModel"]
      resources = [local.profile_arn]
    }
  }

  statement {
    sid       = "BedrockInvokeFoundationModel"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${local.is_profile ? "*" : var.bedrock_region}::foundation-model/${local.profile_match[1]}"]
    dynamic "condition" {
      for_each = local.is_profile ? [1] : []
      content {
        test     = "StringEquals"
        variable = "bedrock:InferenceProfileArn"
        values   = [local.profile_arn]
      }
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = local.name
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}
