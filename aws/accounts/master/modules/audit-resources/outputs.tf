output "cloudtrail_kms_key_arn" {
  description = "ARN of the CloudTrail KMS key"
  value       = aws_kms_key.cloudtrail.arn
}

output "cloudtrail_kms_key_id" {
  description = "ID of the CloudTrail KMS key"
  value       = aws_kms_key.cloudtrail.key_id
}

output "cloudtrail_kms_alias_arn" {
  description = "ARN of the CloudTrail KMS alias"
  value       = aws_kms_alias.cloudtrail.arn
}

output "cloudtrail_bucket_name" {
  description = "Name of the CloudTrail S3 bucket"
  value       = aws_s3_bucket.cloudtrail.id
}

output "cloudtrail_bucket_arn" {
  description = "ARN of the CloudTrail S3 bucket"
  value       = aws_s3_bucket.cloudtrail.arn
}

output "config_kms_key_arn" {
  description = "ARN of the Config KMS key"
  value       = aws_kms_key.config.arn
}

output "config_kms_key_id" {
  description = "ID of the Config KMS key"
  value       = aws_kms_key.config.key_id
}

output "config_bucket_name" {
  description = "Name of the Config S3 bucket"
  value       = aws_s3_bucket.config.id
}

output "config_bucket_arn" {
  description = "ARN of the Config S3 bucket"
  value       = aws_s3_bucket.config.arn
}

output "conformance_bucket_name" {
  description = "Name of the Conformance Pack S3 bucket"
  value       = aws_s3_bucket.conformance.id
}

output "conformance_bucket_arn" {
  description = "ARN of the Conformance Pack S3 bucket"
  value       = aws_s3_bucket.conformance.arn
}
