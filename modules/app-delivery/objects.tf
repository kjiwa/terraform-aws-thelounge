# Zipped, not raw JSON: confirmed live that CodeBuild's DOWNLOAD_SOURCE step
# rejects an unzipped single-file S3 source ("found duplicate source location
# for primary source", CLIENT_ERROR) even once the pipeline role has every
# permission CodePipeline's own docs list -- matching the S3 source action
# reference's own caveat that "downstream actions that expect a .zip file
# will fail" on an unzipped upload. CodeBuild extracts a single-file zip to
# $CODEBUILD_SRC_DIR/<filename>, so this lands at exactly the first path
# buildspec.yml's pre_build already checks ($CODEBUILD_SRC_DIR/desired.json);
# no buildspec change needed.
data "archive_file" "desired" {
  type                    = "zip"
  source_content          = jsonencode({ for k, v in var.desired_state : k => v if k != "plugin_configs" || length(v) > 0 })
  source_content_filename = "desired.json"
  output_path             = "${path.module}/desired.zip"
}

# The pipeline source. Writing this object is the entire deploy trigger: the
# EventBridge rule in codepipeline.tf fires on ObjectCreated for this exact
# key and starts the pipeline. No deploy script -- `terraform apply` after a
# input change on var.desired_state is the deploy.
resource "aws_s3_object" "desired" {
  bucket       = aws_s3_bucket.this.id
  key          = "${local.desired_prefix}/desired.zip"
  source       = data.archive_file.desired.output_path
  etag         = data.archive_file.desired.output_md5
  content_type = "application/zip"
}

# Instance-side config and unit files (config.js, users.json, the converge
# script, systemd units, ...). One object per map entry; etag tracks content
# so an apply updates them in place.
resource "aws_s3_object" "config" {
  for_each = var.config_objects

  bucket = aws_s3_bucket.this.id
  key    = "${local.config_prefix}/${each.key}"

  content = each.value
  etag    = md5(each.value)
}
