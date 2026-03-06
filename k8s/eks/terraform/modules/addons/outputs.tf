output "lb_controller_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller"
  value       = var.enable_aws_lb_controller ? aws_iam_role.lb_controller[0].arn : null
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for the Cluster Autoscaler"
  value       = var.enable_cluster_autoscaler ? aws_iam_role.cluster_autoscaler[0].arn : null
}

output "s3_csi_driver_role_arn" {
  description = "IAM role ARN for the Mountpoint for Amazon S3 CSI Driver"
  value       = var.enable_s3_csi_driver ? aws_iam_role.s3_csi[0].arn : null
}

output "efs_csi_driver_role_arn" {
  description = "IAM role ARN for the Amazon EFS CSI Driver"
  value       = var.enable_efs_csi_driver ? aws_iam_role.efs_csi[0].arn : null
}

output "secrets_store_role_arn" {
  description = "IAM role ARN for the AWS Secrets Store CSI Driver Provider"
  value       = var.enable_secrets_store_csi_driver ? aws_iam_role.secrets_store[0].arn : null
}
