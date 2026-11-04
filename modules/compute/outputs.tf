output "asg_name" {
  description = "Auto Scaling Group name."
  value       = aws_autoscaling_group.this.name
}

output "asg_arn" {
  description = "Auto Scaling Group ARN."
  value       = aws_autoscaling_group.this.arn
}

output "instance_role_name" {
  description = "IAM role name attached to EC2 instances."
  value       = aws_iam_role.instance.name
}

output "instance_role_arn" {
  description = "IAM role ARN attached to EC2 instances. Modules granting the instance additional read access (e.g. the delivery pipeline's artifact bucket) attach their grants to it."
  value       = aws_iam_role.instance.arn
}
