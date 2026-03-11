output "iam_role_arn" {
  description = "ARN of the EKS service IAM role"
  value       = aws_iam_role.eks_service.arn
}

output "iam_role_name" {
  description = "Name of the EKS service IAM role"
  value       = aws_iam_role.eks_service.name
}

output "iam_role_id" {
  description = "ID of the EKS service IAM role"
  value       = aws_iam_role.eks_service.id
}

output "service_account_name" {
  description = "Kubernetes service account name the role is bound to"
  value       = "${lower(var.project)}-${lower(var.environment)}-${lower(var.service)}-sa"
}

output "service_account_namespace" {
  description = "Kubernetes namespace for the service account"
  value       = "${lower(var.project)}-${lower(var.environment)}"
}
