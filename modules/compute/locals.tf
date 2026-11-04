locals {
  # Name/Project tags stay the flat "thelounge" prefix (the watchdogs'
  # self-terminate IAM condition keys on this literal value); account-scoped
  # resource names carry var.env so a second stack in the same account
  # doesn't collide (see var.env's description).
  name     = "thelounge"
  name_env = "${local.name}-${var.env}"
}
