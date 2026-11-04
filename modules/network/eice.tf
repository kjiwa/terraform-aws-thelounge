# Break-glass SSH path: no SSM (ec2messages has no IPv6 endpoint and SSM
# Agent on an IPv6-only instance is untested), so this is the only
# out-of-band way to reach the instance. Free to provision; billed only
# for open-tunnel minutes. The dualstack subnet means AWS can't preserve
# client IP here, which is irrelevant for a single-admin break-glass path
# anyway.
resource "aws_ec2_instance_connect_endpoint" "this" {
  subnet_id          = aws_subnet.this.id
  security_group_ids = [aws_security_group.eice.id]
  preserve_client_ip = false

  tags = {
    Name = "thelounge-eice"
  }
}
