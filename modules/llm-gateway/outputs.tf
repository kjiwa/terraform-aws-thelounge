output "function_name" {
  description = "Gateway Lambda function name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Gateway Lambda function ARN; the only resource the instance role may invoke."
  value       = aws_lambda_function.this.arn
}
