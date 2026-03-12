output "sns_topic_arn" {
  description = "ARN of the root activity SNS topic"
  value       = aws_sns_topic.root_activity.arn
}

output "sns_topic_name" {
  description = "Name of the root activity SNS topic"
  value       = aws_sns_topic.root_activity.name
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule monitoring root sign-in activity"
  value       = aws_cloudwatch_event_rule.root_activity.arn
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.root_activity.name
}
