module "dns" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/dns?ref=v0.2.1"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = "thelounge"
  domains     = { (var.domain_name) = {} }
}

module "thelounge" {
  source = "../.."
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  domain_name = var.domain_name
  zone_id     = module.dns.zone_ids[var.domain_name]
  alert_email = var.alert_email
}

module "audit" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/audit?ref=v0.2.1"

  name_prefix            = "thelounge"
  metric_namespace       = "TheLoungeAudit"
  alert_email            = var.alert_email
  kms_encryption_enabled = false

  log_source_buckets = [{
    name = module.thelounge.delivery_bucket
    arn  = module.thelounge.delivery_bucket_arn
  }]
}

module "finops" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/finops?ref=v0.2.1"

  name_prefix = "thelounge"
  alert_email = var.alert_email
}
