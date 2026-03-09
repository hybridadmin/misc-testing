output "kms_key_arn" {
  description = "ARN of the KMS key used for backup vault encryption"
  value       = aws_kms_key.backup.arn
}

output "kms_key_id" {
  description = "ID of the KMS key used for backup vault encryption"
  value       = aws_kms_key.backup.key_id
}

output "backup_vault_name" {
  description = "Name of the backup vault"
  value       = aws_backup_vault.main.name
}

output "backup_vault_arn" {
  description = "ARN of the backup vault"
  value       = aws_backup_vault.main.arn
}

output "backup_bucket_name" {
  description = "Name of the S3 backup bucket"
  value       = aws_s3_bucket.backup.id
}

output "backup_bucket_arn" {
  description = "ARN of the S3 backup bucket"
  value       = aws_s3_bucket.backup.arn
}

output "cross_account_role_arn" {
  description = "ARN of the cross-account backup role"
  value       = aws_iam_role.devops_backup_access.arn
}
