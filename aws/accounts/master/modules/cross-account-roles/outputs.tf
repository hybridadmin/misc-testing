output "admin_role_arn" {
  description = "ARN of the CrossAccountAdminAccess role"
  value       = aws_iam_role.cross_account_admin.arn
}

output "admin_role_name" {
  description = "Name of the CrossAccountAdminAccess role"
  value       = aws_iam_role.cross_account_admin.name
}

output "read_role_arn" {
  description = "ARN of the CrossAccountReadAccess role"
  value       = aws_iam_role.cross_account_read.arn
}

output "read_role_name" {
  description = "Name of the CrossAccountReadAccess role"
  value       = aws_iam_role.cross_account_read.name
}
