locals {
  # Name/Project tags stay the flat "thelounge" prefix (the watchdogs'
  # self-terminate IAM condition keys on this literal value); account-scoped
  # resource names carry var.env so a second stack in the same account
  # doesn't collide (see var.env's description).
  name     = "thelounge"
  name_env = "${local.name}-${var.env}"

  # Replaces the one instance in place: the data volume attaches to one
  # instance at a time, so a second cannot overlap it. Shared with the AMI
  # updater's forced refresh, which therefore costs the same outage.
  refresh_preferences = {
    min_healthy_percentage = 0
    max_healthy_percentage = 100
  }
}
