# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "add_permissions_lambda_arn" {
  description = "ARN of the Add-Permissions Lambda function"
  value       = aws_lambda_function.add_permissions.arn
}

output "add_permissions_lambda_name" {
  description = "Name of the Add-Permissions Lambda function"
  value       = aws_lambda_function.add_permissions.function_name
}

output "attach_policy_lambda_arn" {
  description = "ARN of the Attach-LifecyclePolicy Lambda function"
  value       = aws_lambda_function.attach_policy.arn
}

output "attach_policy_lambda_name" {
  description = "Name of the Attach-LifecyclePolicy Lambda function"
  value       = aws_lambda_function.attach_policy.function_name
}

output "lambda_role_arn" {
  description = "ARN of the shared Lambda execution role"
  value       = aws_iam_role.lambda.arn
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule for ECR CreateRepository events"
  value       = aws_cloudwatch_event_rule.ecr_create_repo.arn
}

output "add_permissions_log_group_name" {
  description = "Name of the Add-Permissions Lambda CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.add_permissions.name
}

output "attach_policy_log_group_name" {
  description = "Name of the Attach-LifecyclePolicy Lambda CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.attach_policy.name
}
