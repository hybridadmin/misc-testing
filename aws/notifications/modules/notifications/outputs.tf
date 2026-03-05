output "lambda_function_arn" {
  description = "ARN of the Health Events Lambda function"
  value       = aws_lambda_function.health_events.arn
}

output "lambda_function_name" {
  description = "Name of the Health Events Lambda function"
  value       = aws_lambda_function.health_events.function_name
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = aws_iam_role.lambda.arn
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.health_events.arn
}

output "log_group_name" {
  description = "Name of the Lambda CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.lambda.name
}
