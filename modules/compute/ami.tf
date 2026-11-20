# Stock AL2023, not a baked image: patching is dnf-automatic (user_data) plus
# the keel ami-updater, which writes a launch template version for each new
# release. This seeds image_id when a template is created; the template then
# ignores image_id so that Terraform does not revert the updater's versions.
# insecure_value is the non-sensitive twin of value: an AMI ID is not a secret.
data "aws_ssm_parameter" "al2023" {
  for_each = var.ami_ids == null ? local.architectures : toset([])

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${each.key}"
}

# image_id is ignored, so replace_triggered_by is what makes a change of
# ami_ids reach the templates.
resource "terraform_data" "image_pin" {
  input = var.ami_ids
}
