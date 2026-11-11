# Build-and-deliver pipeline for The Lounge. Source (an S3 object this module
# writes from var.desired_state, so an input change *is* the source change)
# -> Build (two parallel CodeBuild projects, one per CPU architecture, each
# fetching thelounge + plugins from npm and publishing a tarball + pointer
# to S3). No Deploy stage: the fleet's own converge timer polls the
# artifacts/current-<arch>.json pointer and pulls the bundle itself.
#
# Deliberately not a GitHub-source/ECR/Docker/CodeDeploy pipeline: the
# instance is IPv4-free, and a pull-based timer needs no inbound path, agent
# or target discovery. npm's registry and CodeDeploy's dual-stack endpoints do
# answer over IPv6, but building in CodeBuild and handing the instance a
# finished tarball over the S3 gateway endpoint keeps the instance's
# footprint to one pointer file and one tarball.
data "aws_caller_identity" "current" {}

locals {
  name       = "thelounge-delivery"
  account_id = data.aws_caller_identity.current.account_id

  # S3 key layout, one bucket for the whole pipeline:
  #   desired/desired.zip   - Terraform-written pipeline source
  #     (aws_s3_object.desired; a zipped desired.json -- see objects.tf for
  #     why unzipped doesn't work). The sole deploy trigger: EventBridge
  #     starts the pipeline on ObjectCreated for exactly this key.
  #   config/<key>          - Terraform-rendered instance config and unit
  #     files from var.config_objects, one object per map entry.
  #   artifacts/             - CodeBuild outputs: artifacts/thelounge-<sha256>
  #     .tar.gz bundles, plus the artifacts/current-<arch>.json pointer each
  #     arch's build overwrites last. The instance's converge timer polls the
  #     pointer. Never expired: the pointer references its bundle
  #     indefinitely, and a quiet month must not strand it.
  #   deployed/current-<arch>.json - the instance's acknowledgement of the
  #     release it applied (written by thelounge-converge.sh, read by
  #     scripts/deploy.sh). Never expired: it is one small object per arch.
  #   <pipeline name, truncated>/ - CodePipeline's own artifact store.
  #     CodePipeline prefixes its S3 artifact keys with the pipeline name
  #     (not configurable) but truncates it to a fixed length (observed:
  #     "thelounge-delivery-prod" -> "thelounge-delivery-p", 20 chars,
  #     undocumented) -- see local.pipeline_store_prefix; the build role's
  #     IAM grant for this prefix is bucket-wide rather than name-matched
  #     (see iam.tf).
  desired_prefix  = "desired"
  config_prefix   = "config"
  artifact_prefix = "artifacts"

  # Resource names the spec fixes as literals (the bucket, already
  # account-scoped by account_id; both CodeBuild projects) stay exactly as
  # given. Everything else this module names is free to collide across a
  # second instantiation in the same account, so it carries var.env.
  name_env = "${local.name}-${var.env}"

  pipeline_store_prefix = substr(local.name_env, 0, 20)
}
