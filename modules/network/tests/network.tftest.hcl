mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_resource "aws_vpc" {
    defaults = { ipv6_cidr_block = "2001:db8:1234:1a00::/56" }
  }
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = { id = "pl-0123456789abcdef0" }
  }
}

mock_provider "dns" {
  mock_data "dns_aaaa_record_set" {
    defaults = { addrs = ["2001:db8::1"] }
  }
}

run "ident_off" {
  command = apply

  assert {
    condition     = aws_route.ipv6_egress.egress_only_gateway_id != null && aws_route.ipv6_egress.gateway_id == null
    error_message = "With ident off, ::/0 must stay on the egress-only gateway."
  }

  assert {
    condition     = length(aws_route.ident_server) == 0 && length(aws_vpc_security_group_ingress_rule.ident_open) == 0 && length(aws_vpc_security_group_ingress_rule.ident_server) == 0
    error_message = "With ident off, no ident route or tcp/113 rule may exist."
  }
}

run "ident_off_ignores_servers" {
  command = apply

  variables {
    ident = { enabled = false, servers = ["irc.example.net"] }
  }

  assert {
    condition     = length(aws_route.ident_server) == 0 && length(aws_vpc_security_group_ingress_rule.ident_server) == 0
    error_message = "Listed servers must do nothing while ident is disabled."
  }
}

run "ident_on_without_servers" {
  command = apply

  variables {
    ident = { enabled = true }
  }

  assert {
    condition     = aws_route.ipv6_egress.gateway_id != null && aws_route.ipv6_egress.egress_only_gateway_id == null
    error_message = "With ident on and no servers, ::/0 must point at the internet gateway."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.ident_open) == 1 && aws_vpc_security_group_ingress_rule.ident_open[0].cidr_ipv6 == "::/0" && aws_vpc_security_group_ingress_rule.ident_open[0].from_port == 113 && aws_vpc_security_group_ingress_rule.ident_open[0].to_port == 113
    error_message = "With ident on and no servers, tcp/113 must open from ::/0."
  }

  assert {
    condition     = length(aws_route.ident_server) == 0 && length(aws_vpc_security_group_ingress_rule.ident_server) == 0
    error_message = "With no servers there are no per-address routes or rules."
  }
}

run "ident_on_with_servers" {
  command = apply

  variables {
    ident = { enabled = true, servers = ["irc.example.net"] }
  }

  assert {
    condition     = aws_route.ipv6_egress.egress_only_gateway_id != null && aws_route.ipv6_egress.gateway_id == null
    error_message = "With servers listed, ::/0 must stay on the egress-only gateway."
  }

  assert {
    condition     = aws_route.ident_server["2001:db8::1"].destination_ipv6_cidr_block == "2001:db8::1/128" && aws_route.ident_server["2001:db8::1"].gateway_id != null
    error_message = "Each server address must get a /128 route through the internet gateway."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.ident_server["2001:db8::1"].cidr_ipv6 == "2001:db8::1/128" && aws_vpc_security_group_ingress_rule.ident_server["2001:db8::1"].from_port == 113
    error_message = "Each server address must get a tcp/113 rule from its /128."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.ident_open) == 0
    error_message = "With servers listed, tcp/113 must not open from ::/0."
  }
}

run "ident_rejects_non_hostname" {
  command = plan

  variables {
    ident = { enabled = true, servers = ["2001:db8::1"] }
  }

  expect_failures = [var.ident]
}
