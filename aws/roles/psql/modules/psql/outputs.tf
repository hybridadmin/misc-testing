output "iam_role_arn" {
  description = "ARN of the PGO service IAM role"
  value       = aws_iam_role.eks_service.arn
}

output "iam_role_name" {
  description = "Name of the PGO service IAM role"
  value       = aws_iam_role.eks_service.name
}

output "iam_role_id" {
  description = "ID of the PGO service IAM role"
  value       = aws_iam_role.eks_service.id
}

output "psql_cluster_name" {
  description = "PGO PostgreSQL cluster name used in service account naming"
  value       = local.psql_cluster_name
}

output "backup_bucket_name" {
  description = "S3 bucket name for pgbackrest backups"
  value       = local.backup_bucket
}

output "service_account_names" {
  description = "Kubernetes service account names the role is bound to"
  value = [
    "${local.psql_cluster_name}-instance",
    "${local.psql_cluster_name}-pgbackrest",
    "${local.psql_cluster_name}-repohost",
  ]
}

output "service_account_namespace" {
  description = "Kubernetes namespace for the service accounts"
  value       = local.namespace
}
