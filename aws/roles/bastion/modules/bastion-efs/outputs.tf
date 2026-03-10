output "efs_id" {
  description = "EFS filesystem ID"
  value       = aws_efs_file_system.bastion.id
}

output "efs_arn" {
  description = "EFS filesystem ARN"
  value       = aws_efs_file_system.bastion.arn
}

output "efs_security_group_id" {
  description = "Security group ID for EFS mount targets"
  value       = aws_security_group.efs.id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for EFS encryption"
  value       = aws_kms_key.efs.arn
}

output "mount_target_ids" {
  description = "List of EFS mount target IDs"
  value       = aws_efs_mount_target.bastion[*].id
}
