locals {
  # Shallow merge, deliberately minimal: only what this architecture
  # requires is pinned here -- private mode, proxy trust for CloudFront,
  # bind-all for the VPC-origin ENI path, and the port the security
  # group/VPC origin/user_data contract all agree on. var.thelounge_config
  # may not set these keys (validated); everything else is left to it and
  # The Lounge's own upstream defaults.
  thelounge_config_defaults = {
    public       = false
    reverseProxy = true
    host         = "::"
    port         = 9000
  }
  thelounge_config_merged = merge(local.thelounge_config_defaults, var.thelounge_config)

  # JSON is valid JS, so config.js can be produced from plain Terraform data
  # (jsonencode) instead of a template file.
  config_js = "module.exports = ${jsonencode(local.thelounge_config_merged)};\n"

  # Fans out build/app/instance/* (converge/watchdog scripts and systemd
  # units) into the config_objects map under an "instance/" prefix. New
  # files dropped there ship to S3, and so to every instance's next converge
  # tick, without touching this root.
  instance_files = {
    for f in fileset("${path.module}/build/app/instance", "*") :
    "instance/${f}" => file("${path.module}/build/app/instance/${f}")
  }

  # Contract: thelounge-converge.sh reads exactly config/instance/* (synced
  # wholesale), config/config.js, and config/users.json. Every key below is
  # one of those three shapes.
  config_objects = merge(local.instance_files, {
    "config.js"  = local.config_js
    "users.json" = jsonencode(var.thelounge_users)
  })

  catchup_enabled = var.catchup.enabled
  catchup_region  = var.catchup.region != "" ? var.catchup.region : data.aws_region.default.region
  catchup_plugin  = "thelounge-plugin-catchup"

  # thelounge-vault-reader is a fixed name in the backup account (keel's
  # backup-vault-account module), so its ARN is constructed the same way the
  # destination vault ARN is: a name contract, not cross-account remote state.
  # Empty except under cross_account, matching when the status Lambda assumes it.
  backup_dest_reader_role_arn = (
    var.backup.mode == "cross_account"
    ? "arn:aws:iam::${var.backup.account_id}:role/thelounge-vault-reader"
    : ""
  )

  # Panels the static status shell hides before its first data fetch resolves
  # (config.js): everything this stack does not feed the core.
  status_disabled_panels = compact([
    var.backup.mode == "disabled" ? "backups" : "",
    "deployment",
    "cost",
    "host_metrics",
    var.status.bedrock ? "" : "bedrock",
  ])

  plugins = concat(
    var.thelounge_plugins,
    local.catchup_enabled ? ["${local.catchup_plugin}@${var.catchup.version}"] : [],
  )

  # Written by the build to packages/<name>/config.json, the plugin's
  # persistent storage directory.
  plugin_configs = local.catchup_enabled ? {
    (local.catchup_plugin) = merge({
      provider       = var.catchup.provider
      function       = one(module.llm_gateway[*].function_name)
      region         = data.aws_region.default.region
      maxWindowHours = var.catchup.max_window_hours
    }, var.catchup.time_zone != "" ? { timeZone = var.catchup.time_zone } : {})
  } : {}
}
