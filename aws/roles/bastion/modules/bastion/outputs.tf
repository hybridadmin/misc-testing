output "elastic_ip" {
  description = "Bastion Elastic IP address"
  value       = aws_eip.bastion.public_ip
}

output "elastic_ip_allocation_id" {
  description = "Bastion Elastic IP allocation ID"
  value       = aws_eip.bastion.allocation_id
}

output "ssh_port" {
  description = "SSH port configured for the bastion"
  value       = var.ssh_port
}

output "instance_role_arn" {
  description = "ARN of the bastion IAM role"
  value       = aws_iam_role.bastion.arn
}

output "instance_profile_arn" {
  description = "ARN of the bastion instance profile"
  value       = aws_iam_instance_profile.bastion.arn
}

output "security_group_id" {
  description = "Bastion security group ID"
  value       = aws_security_group.bastion.id
}

output "launch_template_id" {
  description = "Launch template ID"
  value       = aws_launch_template.bastion.id
}

output "autoscaling_group_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.bastion.name
}

output "service_discovery_service_id" {
  description = "Cloud Map Service Discovery service ID"
  value       = aws_service_discovery_service.bastion.id
}

output "log_group_names" {
  description = "Map of CloudWatch Log Group names"
  value       = { for k, v in aws_cloudwatch_log_group.bastion : k => v.name }
}

output "cpu_alarm_arn" {
  description = "ARN of the high CPU CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.high_cpu.arn
}
