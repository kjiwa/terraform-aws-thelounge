# --- CodeBuild role (shared by both architectures) ---------------------------

data "aws_iam_policy_document" "build_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "build" {
  name               = "${local.name_env}-build"
  assume_role_policy = data.aws_iam_policy_document.build_assume.json

  tags = {
    Name = "${local.name_env}-build"
  }
}

data "aws_iam_policy_document" "build" {
  statement {
    sid       = "GetDesiredState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/${local.desired_prefix}/*"]
  }

  statement {
    sid       = "ReadWriteArtifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/${local.artifact_prefix}/*"]
  }

  # CodePipeline's own artifact store (main.tf's prefix layout), NOT scoped
  # to local.name_env: CodePipeline truncates the pipeline name to an
  # undocumented fixed length when building this prefix, so the wildcard
  # stays and cannot be narrowed to a prefix. The Deny below closes what the
  # wildcard would otherwise grant: writing the prefixes the instance trusts
  # (converge installs config/ as root) and reading config/users.json.
  statement {
    sid       = "ReadWritePipelineArtifactStore"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    sid     = "DenyWriteTrustedPrefixes"
    effect  = "Deny"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.this.arn}/${local.config_prefix}/*",
      "${aws_s3_bucket.this.arn}/${local.desired_prefix}/*",
      "${aws_s3_bucket.this.arn}/deployed/*",
    ]
  }

  statement {
    sid       = "DenyReadConfig"
    effect    = "Deny"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/${local.config_prefix}/*"]
  }

  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = flatten([for lg in aws_cloudwatch_log_group.build : [lg.arn, "${lg.arn}:*"]])
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "${local.name_env}-build"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}

# --- CodePipeline role ---------------------------------------------------------

data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${local.name_env}-pipeline"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json

  tags = {
    Name = "${local.name_env}-pipeline"
  }
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid    = "Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject",
      "s3:GetBucketLocation", "s3:ListBucket",
      # AWS's documented S3-source-action service role permissions, plus
      # ListBucketVersions (undocumented but required). Any one missing
      # fails Source with the same generic "provided role does not have
      # permissions" error.
      "s3:GetBucketVersioning",
      "s3:GetBucketAcl",
      "s3:GetObjectTagging",
      "s3:GetObjectVersionTagging",
      "s3:ListBucketVersions",
      # Write-side counterparts: Source's own write of its staged output
      # artifact sets bucket-owner-full-control and propagates tags.
      "s3:PutObjectAcl",
      "s3:PutObjectTagging",
    ]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    sid       = "RunBuild"
    effect    = "Allow"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [for p in aws_codebuild_project.build : p.arn]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "${local.name_env}-pipeline"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# --- EventBridge invocation role ------------------------------------------------

data "aws_iam_policy_document" "events_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "${local.name_env}-events"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json

  tags = {
    Name = "${local.name_env}-events"
  }
}

data "aws_iam_policy_document" "events" {
  statement {
    sid       = "StartPipeline"
    effect    = "Allow"
    actions   = ["codepipeline:StartPipelineExecution"]
    resources = [aws_codepipeline.this.arn]
  }
}

resource "aws_iam_role_policy" "events" {
  name   = "${local.name_env}-events"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events.json
}
