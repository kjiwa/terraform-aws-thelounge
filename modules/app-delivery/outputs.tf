output "bucket_name" {
  description = "Delivery bucket name."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "Delivery bucket ARN."
  value       = aws_s3_bucket.this.arn
}

output "config_prefix" {
  description = "S3 key prefix (under bucket_name) holding var.config_objects, one object per map entry at <config_prefix>/<key>."
  value       = local.config_prefix
}

output "artifact_prefix" {
  description = "S3 key prefix (under bucket_name) holding build outputs: <artifact_prefix>/thelounge-<sha256>.tar.gz bundles and the <artifact_prefix>/current-<arch>.json pointers the instance's converge timer polls."
  value       = local.artifact_prefix
}

output "pipeline_name" {
  description = "CodePipeline name."
  value       = aws_codepipeline.this.name
}

output "pipeline_arn" {
  description = "CodePipeline ARN."
  value       = aws_codepipeline.this.arn
}
