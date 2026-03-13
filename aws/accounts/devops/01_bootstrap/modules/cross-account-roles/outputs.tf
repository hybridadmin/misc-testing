output "cfn_execution_policy_arn" {
  description = "ARN of the CloudFormation execution managed policy"
  value       = aws_iam_policy.cfn_execution.arn
}

output "cfn_execution_policy_name" {
  description = "Name of the CloudFormation execution managed policy"
  value       = aws_iam_policy.cfn_execution.name
}

output "stackset_execution_role_arn" {
  description = "ARN of the StackSet execution role"
  value       = aws_iam_role.stackset_execution.arn
}

output "stackset_execution_role_name" {
  description = "Name of the StackSet execution role"
  value       = aws_iam_role.stackset_execution.name
}

output "stackset_admin_role_arn" {
  description = "ARN of the StackSet administration role"
  value       = aws_iam_role.stackset_admin.arn
}

output "stackset_admin_role_name" {
  description = "Name of the StackSet administration role"
  value       = aws_iam_role.stackset_admin.name
}

output "devops_deployment_role_arn" {
  description = "ARN of the DevOps deployment role"
  value       = aws_iam_role.devops_deployment.arn
}

output "devops_deployment_role_name" {
  description = "Name of the DevOps deployment role"
  value       = aws_iam_role.devops_deployment.name
}
