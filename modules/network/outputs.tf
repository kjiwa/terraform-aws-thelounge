output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC IPv4 CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "subnet_id" {
  description = "Subnet ID. The compute module's ASG and the CloudFront VPC origin both launch ENIs here."
  value       = aws_subnet.this.id
}

output "az" {
  description = "Resolved availability zone: var.az, or the first available AZ when it was null."
  value       = local.az
}

output "app_sg_id" {
  description = "thelounge-app security group ID. Attached to the instance."
  value       = aws_security_group.app.id
}

output "eice_sg_id" {
  description = "thelounge-eice security group ID."
  value       = aws_security_group.eice.id
}

output "route_table_id" {
  description = "Subnet route table ID."
  value       = aws_route_table.this.id
}

output "eip_allocation_id" {
  description = "Elastic IP allocation ID, or null when enable_public_ipv4 is false. The instance associates it at boot."
  value       = one(aws_eip.this[*].id)
}

output "eip_public_dns" {
  description = "Elastic IP public DNS name, or null when enable_public_ipv4 is false."
  value       = one(aws_eip.this[*].public_dns)
}
