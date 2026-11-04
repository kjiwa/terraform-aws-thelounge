# Source (S3: desired/desired.zip) -> Build (two parallel CodeBuild
# actions, arm64 and x86_64, same source in). No Deploy stage -- see main.tf.
resource "aws_codepipeline" "this" {
  name          = local.name_env
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"

  # A V2 pipeline auto-fires one execution the instant it's created. Without
  # this, that create-time run can race ahead of the role policies' IAM
  # propagation and fail Source (and, since Source feeds straight into
  # Build, the build role too) with "the provided role does not have
  # permissions" -- exactly what left artifacts/ empty on first apply. Same
  # guard the compute module's ASG uses against aws_iam_role_policy.instance.
  depends_on = [aws_iam_role_policy.pipeline, aws_iam_role_policy.build]

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.this.bucket
  }

  # PollForSourceChanges = false: the EventBridge rule below is the trigger,
  # not periodic polling.
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        S3Bucket             = aws_s3_bucket.this.bucket
        S3ObjectKey          = aws_s3_object.desired.key
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name            = "BuildArm64"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]

      configuration = {
        ProjectName = aws_codebuild_project.build["arm64"].name
      }
    }

    action {
      name            = "BuildX86_64"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]

      configuration = {
        ProjectName = aws_codebuild_project.build["x86_64"].name
      }
    }
  }

  tags = {
    Name = local.name_env
  }
}

# EventBridge (not polling) drives the Source stage: S3 notifications are
# enabled bucket-wide (aws_s3_bucket_notification.this), and this rule narrows
# that stream to exactly the one key that matters.
resource "aws_cloudwatch_event_rule" "trigger" {
  name        = "${local.name_env}-trigger"
  description = "Starts the pipeline when desired/desired.zip is (re)written."

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.this.bucket] }
      object = { key = [aws_s3_object.desired.key] }
    }
  })

  tags = {
    Name = "${local.name_env}-trigger"
  }
}

resource "aws_cloudwatch_event_target" "trigger" {
  rule      = aws_cloudwatch_event_rule.trigger.name
  target_id = "codepipeline"
  arn       = aws_codepipeline.this.arn
  role_arn  = aws_iam_role.events.arn
}
