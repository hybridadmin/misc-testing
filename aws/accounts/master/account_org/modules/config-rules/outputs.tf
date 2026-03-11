output "s3_mandatory_tags_rule_arn" {
  description = "ARN of the S3 mandatory tags Config rule"
  value       = aws_config_config_rule.s3_mandatory_tags.arn
}

output "ssm_document_name" {
  description = "Name of the SNS notification SSM automation document"
  value       = aws_ssm_document.sns_notification_remediation.name
}
