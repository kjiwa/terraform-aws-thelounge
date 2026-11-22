# IRC servers connect back to tcp/113 to ask who owns a connection. The
# egress-only gateway drops that inbound flow, so ident needs a route through
# the internet gateway, which has no charge.
#
# With no servers listed, the whole IPv6 default route moves to the internet
# gateway (routing.tf) and tcp/113 opens to ::/0. With servers, each resolved
# address gets its own /128 route and rule, and everything else stays on the
# egress-only gateway.
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

resource "aws_route" "ident_server" {
  for_each                    = local.ident_addresses
  route_table_id              = aws_route_table.this.id
  destination_ipv6_cidr_block = "${each.value}/128"
  gateway_id                  = aws_internet_gateway.this.id
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
