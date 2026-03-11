###############################################################################
# Admin Role Outputs
###############################################################################

output "admin_role_arn" {
  description = "ARN of the cross-account admin access IAM role."
  value       = aws_iam_role.admin.arn
}

output "admin_role_name" {
  description = "Name of the cross-account admin access IAM role."
  value       = aws_iam_role.admin.name
}

output "admin_role_id" {
  description = "Unique ID of the cross-account admin access IAM role."
  value       = aws_iam_role.admin.unique_id
}

###############################################################################
# Read-Only Role Outputs
###############################################################################

output "read_only_role_arn" {
  description = "ARN of the cross-account read-only access IAM role."
  value       = aws_iam_role.read_only.arn
}

output "read_only_role_name" {
  description = "Name of the cross-account read-only access IAM role."
  value       = aws_iam_role.read_only.name
}

output "read_only_role_id" {
  description = "Unique ID of the cross-account read-only access IAM role."
  value       = aws_iam_role.read_only.unique_id
}
