# Stock AL2023, not a baked image: patching is dnf-automatic (user_data)
# plus periodic AMI moves. These SSM public parameters resolve to the latest
# AL2023 release per architecture; var.ami_ids pins the fleet instead. They
# are read even when pinned, so a plan can warn that the pin is stale.
# insecure_value is the non-sensitive twin of value: an AMI ID is not a secret.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_ssm_parameter" "al2023_x86_64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  latest_ami_ids = {
    arm64  = data.aws_ssm_parameter.al2023_arm64.insecure_value
    x86_64 = data.aws_ssm_parameter.al2023_x86_64.insecure_value
  }
  ami_ids = var.ami_ids != null ? var.ami_ids : local.latest_ami_ids
  stale_ami_ids = {
    for architecture, id in local.ami_ids : architecture => local.latest_ami_ids[architecture]
    if id != local.latest_ami_ids[architecture]
  }
}

check "ami_ids_are_latest" {
  assert {
    condition     = length(local.stale_ami_ids) == 0
    error_message = "ami_ids is behind the latest AL2023: ${join(", ", [for architecture, latest in local.stale_ami_ids : "${architecture} ${local.ami_ids[architecture]} -> ${latest}"])}."
  }
}
