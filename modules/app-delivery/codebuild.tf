# One buildspec, both architectures (build/app/buildspec.yml branches on
# $ARCH). Inlined via file() rather than referenced by path: the pipeline's
# source artifact is desired.json alone (zipped as desired.zip for the S3
# source action -- see objects.tf -- and unzipped by CodeBuild back to
# $CODEBUILD_SRC_DIR/desired.json), not a repo checkout, so there is no
# source tree for CodeBuild to resolve a buildspec path against.
#
# thelounge's storage layer compiles native modules (better-sqlite3), so each
# bundle is architecture-specific -- the build MUST run on the architecture it
# targets, or the compiled binary segfaults on the fleet. That is why this is
# two projects rather than one project building both.
locals {
  build_projects = {
    arm64 = {
      image = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
      type  = "ARM_CONTAINER"
    }
    x86_64 = {
      image = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
      type  = "LINUX_CONTAINER"
    }
  }
}

resource "aws_cloudwatch_log_group" "build" {
  for_each = local.build_projects

  name              = "/aws/codebuild/thelounge-build-${each.key}"
  retention_in_days = 30

  tags = {
    Name = "thelounge-build-${each.key}"
  }
}

resource "aws_codebuild_project" "build" {
  for_each = local.build_projects

  name         = "thelounge-build-${each.key}"
  description  = "Builds the ${each.key} thelounge bundle (Node runtime + app + plugins) and publishes it to S3."
  service_role = aws_iam_role.build.arn

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/../../build/app/buildspec.yml")
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type            = each.value.type
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = each.value.image
    privileged_mode = false

    environment_variable {
      name  = "ARCH"
      value = each.key
    }
    environment_variable {
      name  = "BUCKET"
      value = aws_s3_bucket.this.bucket
    }
    environment_variable {
      name  = "ARTIFACT_PREFIX"
      value = local.artifact_prefix
    }
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.build[each.key].name
    }
  }

  tags = {
    Name = "thelounge-build-${each.key}"
  }
}
