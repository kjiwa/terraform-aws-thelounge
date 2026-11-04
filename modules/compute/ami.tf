# Stock AL2023, not a baked image: patching is dnf-automatic (user_data)
# plus periodic AMI moves. These SSM public parameters resolve to the latest
# AL2023 release per architecture; var.ami_ids pins the fleet instead.
data "aws_ssm_parameter" "al2023_arm64" {
  count = var.ami_ids == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_ssm_parameter" "al2023_x86_64" {
  count = var.ami_ids == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_ids = var.ami_ids != null ? var.ami_ids : {
    arm64  = data.aws_ssm_parameter.al2023_arm64[0].value
    x86_64 = data.aws_ssm_parameter.al2023_x86_64[0].value
  }
}
