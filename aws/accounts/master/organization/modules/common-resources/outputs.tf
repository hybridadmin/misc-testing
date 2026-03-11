output "deployment_bucket_name" {
  description = "Name of the deployment S3 bucket"
  value       = aws_s3_bucket.deployment.id
}

output "deployment_bucket_arn" {
  description = "ARN of the deployment S3 bucket"
  value       = aws_s3_bucket.deployment.arn
}

output "critical_sns_topic_arn" {
  description = "ARN of the critical notifications SNS topic"
  value       = aws_sns_topic.critical.arn
}

output "general_sns_topic_arn" {
  description = "ARN of the general notifications SNS topic"
  value       = aws_sns_topic.general.arn
}
