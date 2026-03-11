output "efs_id" {
  description = "EFS filesystem ID"
  value       = aws_efs_file_system.this.id
}

output "efs_arn" {
  description = "EFS filesystem ARN"
  value       = aws_efs_file_system.this.arn
}

output "efs_dns_name" {
  description = "EFS filesystem DNS name"
  value       = aws_efs_file_system.this.dns_name
}

output "security_group_id" {
  description = "Security group ID for EFS mount targets"
  value       = aws_security_group.efs.id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for EFS encryption"
  value       = aws_kms_key.efs.arn
}

output "kms_key_id" {
  description = "ID of the KMS key used for EFS encryption"
  value       = aws_kms_key.efs.key_id
}

output "mount_target_ids" {
  description = "List of EFS mount target IDs"
  value       = aws_efs_mount_target.this[*].id
}

output "mount_target_dns_names" {
  description = "List of EFS mount target DNS names"
  value       = aws_efs_mount_target.this[*].dns_name
}
