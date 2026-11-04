locals {
  name = "thelounge-llm-gateway-${var.env}"
}

data "archive_file" "this" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

resource "aws_lambda_function" "this" {
  function_name    = local.name
  role             = aws_iam_role.this.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  memory_size      = 128
  timeout          = 30

  # Not in a VPC: a VPC attachment would need NAT or an endpoint to reach
  # Bedrock. No reserved_concurrent_executions: the account's unreserved
  # concurrency is already at AWS's floor of 10.

  depends_on = [aws_cloudwatch_log_group.this]

  environment {
    variables = {
      MODEL_ID       = var.model_id
      BEDROCK_REGION = var.bedrock_region
    }
  }

  tags = {
    Name = local.name
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 7

  tags = {
    Name = local.name
  }
}
