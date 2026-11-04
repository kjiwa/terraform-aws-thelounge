data "aws_region" "default" {}

module "network" {
  source = "./modules/network"

  az                 = var.az
  enable_public_ipv4 = var.enable_public_ipv4
}

module "app_delivery" {
  source = "./modules/app-delivery"

  env = var.env
  desired_state = {
    thelounge_version = var.thelounge_version
    node_version      = var.node_version
    plugins           = local.plugins
    plugin_configs    = local.plugin_configs
  }
  config_objects = local.config_objects
}

module "storage" {
  source = "./modules/storage"

  az                      = module.network.az
  data_volume_size_gb     = var.data_volume_size_gb
  data_volume_snapshot_id = var.data_volume_snapshot_id
  backup                  = var.backup
  backup_region           = var.backup_region
}

module "compute" {
  source = "./modules/compute"

  env                        = var.env
  active                     = var.active
  spot_enabled               = var.spot_enabled
  cpu_credits                = var.cpu_credits
  instance_requirements      = var.instance_requirements
  ami_ids                    = var.ami_ids
  subnet_id                  = module.network.subnet_id
  app_sg_id                  = module.network.app_sg_id
  ebs_volume_id              = module.storage.volume_id
  ebs_volume_arn             = module.storage.volume_arn
  ebs_kms_key_arn            = module.storage.volume_kms_key_arn
  config_bucket_name         = module.app_delivery.bucket_name
  config_bucket_arn          = module.app_delivery.bucket_arn
  rightsize_schedule         = var.rightsize_schedule
  rightsize_min_uptime_hours = var.rightsize_min_uptime_hours
  eip_allocation_id          = module.network.eip_allocation_id
  region                     = data.aws_region.default.region
  llm_gateway_function_arn   = one(module.llm_gateway[*].function_arn)
}

module "llm_gateway" {
  source = "./modules/llm-gateway"
  count  = local.catchup_enabled ? 1 : 0

  env            = var.env
  model_id       = var.catchup.model_id
  bedrock_region = local.catchup_region
}

module "edge" {
  source = "./modules/edge"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  domain_name          = var.domain_name
  hostname             = var.hostname
  zone_id              = var.zone_id
  active               = var.active
  region               = data.aws_region.default.region
  enable_public_ipv4   = var.enable_public_ipv4
  public_origin_domain = module.network.eip_public_dns

  status_origins   = var.status.enabled ? module.status[0].origins : []
  status_behaviors = var.status.enabled ? module.status[0].behaviors : []
}

module "monitoring" {
  source = "./modules/monitoring"

  primary_domain = module.edge.fqdn
  asg_name       = module.compute.asg_name
  active         = var.active
  alert_email    = var.alert_email
  backup_enabled = var.backup.mode != "disabled"

  disk_alarm_used_percent = var.disk_alarm_used_percent
}

# Authenticated operational status page at /status (see the status variable).
module "status" {
  source = "./modules/status"
  count  = var.status.enabled ? 1 : 0

  primary_domain               = module.edge.fqdn
  distribution_arn             = module.edge.distribution_arn
  asg_name                     = module.compute.asg_name
  episodes_log_group           = module.monitoring.episodes_log_group_name
  spot_interruptions_log_group = module.monitoring.spot_interruptions_log_group_name
  spot_enabled                 = var.spot_enabled
  public_reliability           = var.status.public_reliability
  ebs_volume_id                = module.storage.volume_id
  disabled_panels              = local.status_disabled_panels

  bedrock = var.status.bedrock ? {
    region   = local.catchup_region
    model_id = var.catchup.model_id
  } : null

  backup = var.backup.mode == "disabled" ? null : {
    vault_name            = module.storage.vault_name
    mode                  = var.backup.mode
    schedule              = var.backup.schedule
    retention_days        = var.backup.retention_days
    resource_count        = module.storage.backup_resource_count
    remote_retention_days = module.storage.backup_remote_retention_days
    region                = var.backup_region
    copy_vault_arn        = module.storage.backup_copy_vault_arn == null ? "" : module.storage.backup_copy_vault_arn
    dest_reader_role_arn  = local.backup_dest_reader_role_arn
  }
}
