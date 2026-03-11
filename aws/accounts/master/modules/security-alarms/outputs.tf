output "cloudtrail_log_group_arn" {
  description = "ARN of the CloudTrail CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.cloudtrail.arn
}

output "cloudtrail_bucket_name" {
  description = "Name of the CloudTrail S3 bucket"
  value       = aws_s3_bucket.cloudtrail.id
}

output "cloudtrail_arn" {
  description = "ARN of the CloudTrail trail"
  value       = aws_cloudtrail.main.arn
}

output "security_sns_topic_arn" {
  description = "ARN of the security alerts SNS topic"
  value       = aws_sns_topic.security.arn
}
