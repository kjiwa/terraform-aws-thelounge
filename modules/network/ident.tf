# IRC servers connect back to tcp/113 to ask who owns a connection. The
# egress-only gateway drops that inbound flow, so with ident on the IPv6
# default route moves to the internet gateway (routing.tf), which has no
# charge. AWS refuses a narrower IPv6 route through an internet gateway in a
# table that has an egress-only gateway route, so the security group alone
# decides inbound: tcp/113 from ::/0 with no servers listed, or from each
# resolved address with servers.
locals {
  ident_open    = var.ident.enabled && length(var.ident.servers) == 0
  ident_servers = var.ident.enabled ? toset(var.ident.servers) : toset([])
  ident_addresses = toset(flatten([
    for r in data.dns_aaaa_record_set.ident : r.addrs
  ]))
}

# A host with no AAAA record fails the plan, and a changed address shows up as
# a diff on the next plan.
data "dns_aaaa_record_set" "ident" {
  for_each = local.ident_servers
  host     = each.value
}

resource "aws_vpc_security_group_ingress_rule" "ident_open" {
  count             = local.ident_open ? 1 : 0
  security_group_id = aws_security_group.app.id
  description       = "ident (113/tcp) from any IRC server."
  ip_protocol       = "tcp"
  from_port         = 113
  to_port           = 113
  cidr_ipv6         = "::/0"
}

resource "aws_vpc_security_group_ingress_rule" "ident_server" {
  for_each          = local.ident_addresses
  security_group_id = aws_security_group.app.id
  description       = "ident (113/tcp) from a listed IRC server."
  ip_protocol       = "tcp"
  from_port         = 113
  to_port           = 113
  cidr_ipv6         = "${each.value}/128"
}
