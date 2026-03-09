###############################################################################
# KMS Key Outputs
###############################################################################

output "kms_key_arn" {
  description = "ARN of the backup vault KMS key."
  value       = aws_kms_key.backup.arn
}

output "kms_key_id" {
  description = "ID of the backup vault KMS key."
  value       = aws_kms_key.backup.key_id
}

output "kms_alias_arn" {
  description = "ARN of the backup vault KMS key alias."
  value       = aws_kms_alias.backup.arn
}

###############################################################################
# Backup Vault Outputs
###############################################################################

output "vault_arn" {
  description = "ARN of the AWS Backup vault."
  value       = aws_backup_vault.this.arn
}

output "vault_name" {
  description = "Name of the AWS Backup vault."
  value       = aws_backup_vault.this.name
}

###############################################################################
# S3 Bucket Outputs
###############################################################################

output "bucket_arn" {
  description = "ARN of the backup S3 bucket."
  value       = aws_s3_bucket.backup.arn
}

output "bucket_name" {
  description = "Name of the backup S3 bucket."
  value       = aws_s3_bucket.backup.id
}

###############################################################################
# IAM Role Outputs
###############################################################################

output "cross_account_role_arn" {
  description = "ARN of the cross-account backup IAM role."
  value       = aws_iam_role.cross_account_backup.arn
}

output "cross_account_role_name" {
  description = "Name of the cross-account backup IAM role."
  value       = aws_iam_role.cross_account_backup.name
}
