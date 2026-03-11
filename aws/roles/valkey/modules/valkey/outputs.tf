output "iam_role_arns" {
  description = "Map of valkey instance name to IAM role ARN"
  value       = { for k, v in aws_iam_role.valkey : k => v.arn }
}

output "iam_role_names" {
  description = "Map of valkey instance name to IAM role name"
  value       = { for k, v in aws_iam_role.valkey : k => v.name }
}

output "iam_role_ids" {
  description = "Map of valkey instance name to IAM role ID"
  value       = { for k, v in aws_iam_role.valkey : k => v.id }
}

output "service_account_names" {
  description = "Map of valkey instance name to Kubernetes service account name"
  value = {
    for inst in var.valkey_instances :
    inst => "${lower(var.project)}-${lower(var.environment)}-${lower(inst)}-${lower(var.role_name)}-sa"
  }
}

output "service_account_namespace" {
  description = "Kubernetes namespace for the service accounts"
  value       = "${lower(var.project)}-${lower(var.environment)}"
}
