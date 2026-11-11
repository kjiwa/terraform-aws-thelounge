mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::thelounge-delivery-123456789012" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock" }
  }
  mock_resource "aws_codebuild_project" {
    defaults = { arn = "arn:aws:codebuild:us-east-1:123456789012:project/mock" }
  }
  mock_resource "aws_codepipeline" {
    defaults = { arn = "arn:aws:codepipeline:us-east-1:123456789012:mock" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  env = "prod"
  desired_state = {
    thelounge_version = "4.4.3"
    node_version      = "22.23.5"
    plugins           = []
  }
  config_objects = { "config.js" = "module.exports = {};" }
}

run "build_role_cannot_write_trusted_prefixes" {
  command = apply

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.build.statement :
      s.effect == "Deny" && contains(s.actions, "s3:PutObject")
      && s.resources == toset([
        "arn:aws:s3:::thelounge-delivery-123456789012/config/*",
        "arn:aws:s3:::thelounge-delivery-123456789012/desired/*",
        "arn:aws:s3:::thelounge-delivery-123456789012/deployed/*",
      ])
    ])
    error_message = "The build role needs an explicit Deny of s3:PutObject on config/*, desired/* and deployed/*."
  }
}

run "build_role_cannot_read_config" {
  command = apply

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.build.statement :
      s.effect == "Deny" && contains(s.actions, "s3:GetObject")
      && s.resources == toset(["arn:aws:s3:::thelounge-delivery-123456789012/config/*"])
    ])
    error_message = "The build role needs an explicit Deny of s3:GetObject on config/*."
  }
}

run "pipeline_artifact_expiry_matches_truncated_prefix" {
  command = apply

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_lifecycle_configuration.this.rule :
      r.id == "expire-pipeline-artifact-store" && one(r.filter).prefix == "thelounge-delivery-p/"
    ])
    error_message = "The expiry rule must filter CodePipeline's 20-character truncated prefix thelounge-delivery-p/."
  }
}
