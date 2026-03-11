output "backup_role_arn" {
  description = "ARN of the ORGRoleForBackupServices role"
  value       = aws_iam_role.backup_access.arn
}

output "backup_role_name" {
  description = "Name of the backup access role"
  value       = aws_iam_role.backup_access.name
}

output "route53_role_arn" {
  description = "ARN of the Route53 access role"
  value       = aws_iam_role.route53_access.arn
}

output "route53_role_name" {
  description = "Name of the Route53 access role"
  value       = aws_iam_role.route53_access.name
}
