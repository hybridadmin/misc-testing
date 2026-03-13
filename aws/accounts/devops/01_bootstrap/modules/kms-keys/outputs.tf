output "key_arn" {
  description = "ARN of the KMS key"
  value       = aws_kms_key.ami_encryption.arn
}

output "key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.ami_encryption.key_id
}

output "alias_arn" {
  description = "ARN of the KMS key alias"
  value       = aws_kms_alias.ami_encryption.arn
}

output "alias_name" {
  description = "Name of the KMS key alias"
  value       = aws_kms_alias.ami_encryption.name
}
