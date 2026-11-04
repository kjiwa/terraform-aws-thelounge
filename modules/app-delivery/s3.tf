# The pipeline's one bucket: source (desired/), rendered instance config
# (config/), build outputs (artifacts/), the instance's release
# acknowledgement (deployed/), and CodePipeline's own artifact store (see the prefix layout in main.tf).
resource "aws_s3_bucket" "this" {
  bucket = "${local.name}-${local.account_id}"

  tags = {
    Name = local.name
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Required: CodePipeline's S3 source action polls versions, not just keys.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# TLS-only, matching every other bucket in this stack.
data "aws_iam_policy_document" "this" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.this.json
}

# Drives the EventBridge rule in codepipeline.tf that starts the pipeline --
# the whole deploy trigger lives on this one setting plus that one rule.
resource "aws_s3_bucket_notification" "this" {
  bucket      = aws_s3_bucket.this.id
  eventbridge = true
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket     = aws_s3_bucket.this.id
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    expiration {
      expired_object_delete_marker = true
    }
  }

  # CodePipeline's own artifact store (see main.tf); every execution writes a
  # fresh copy of the source object plus per-action output, so it churns and
  # is never worth keeping past the run that produced it.
  rule {
    id     = "expire-pipeline-artifact-store"
    status = "Enabled"
    filter {
      prefix = "${local.name_env}/"
    }
    expiration {
      days = 7
    }
  }
}
