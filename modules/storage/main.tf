locals {
  name_prefix = "thelounge"
}

module "data_volume" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/data-volume?ref=v0.2.0"

  name_prefix   = local.name_prefix
  az            = var.az
  size_gib      = var.data_volume_size_gb
  snapshot_id   = var.data_volume_snapshot_id
  backup        = var.backup
  backup_region = var.backup_region
}
