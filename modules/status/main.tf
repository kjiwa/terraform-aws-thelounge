# TheLounge layer over the status-page core: maps this module's inputs onto the
# core's objects and supplies plugin/plugin.py and config.js.tpl. The root
# attaches the origins and behaviors outputs to the distribution in modules/edge.
module "core" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/status?ref=v0.3.0"

  name_prefix      = "thelounge"
  bucket_name      = "${replace(var.primary_domain, ".", "-")}-status"
  auth_header      = "X-Lounge-Token"
  distribution_arn = var.distribution_arn
  asg_name         = var.asg_name

  episodes_log_group           = var.episodes_log_group
  spot_interruptions_log_group = var.spot_interruptions_log_group
  siteup_metric_namespace      = "TheLounge"

  spot_enabled       = var.spot_enabled
  public_reliability = var.public_reliability
  ebs_volume_id      = var.ebs_volume_id
  bedrock            = var.bedrock
  backup             = var.backup

  # The account's Lambda concurrency quota is 10, which AWS requires to stay
  # unreserved in full; -1 reserves nothing.
  reserved_concurrency = -1

  plugin_dir         = "${path.module}/plugin"
  plugin_environment = { SITE_URL = "https://${var.primary_domain}" }

  config_js = templatefile("${path.module}/config.js.tpl", { disabled = var.disabled_panels })
}
