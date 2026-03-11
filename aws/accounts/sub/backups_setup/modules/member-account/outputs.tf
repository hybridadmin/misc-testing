output "kms_key_arn" {
  description = "ARN of the KMS key used for backup vault encryption"
  value       = aws_kms_key.backup.arn
}

output "backup_vault_name" {
  description = "Name of the backup vault"
  value       = aws_backup_vault.main.name
}

output "backup_vault_arn" {
  description = "ARN of the backup vault"
  value       = aws_backup_vault.main.arn
}

output "backup_selection_role_arn" {
  description = "ARN of the backup selection IAM role"
  value       = aws_iam_role.backup_selection.arn
}

output "cross_account_role_arn" {
  description = "ARN of the cross-account backup role (empty if not created)"
  value       = var.enable_cross_account_role ? aws_iam_role.devops_backup_access[0].arn : ""
}
