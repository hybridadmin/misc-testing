variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  type        = string
}

variable "oidc_provider_id" {
  description = "OIDC provider ID (issuer URL without https://)"
  type        = string
}

variable "enable_aws_lb_controller" {
  description = "Deploy AWS Load Balancer Controller"
  type        = bool
  default     = true
}

variable "enable_cluster_autoscaler" {
  description = "Deploy Cluster Autoscaler"
  type        = bool
  default     = true
}

variable "enable_metrics_server" {
  description = "Deploy Metrics Server for HPA"
  type        = bool
  default     = true
}

variable "enable_s3_csi_driver" {
  description = "Deploy the Mountpoint for Amazon S3 CSI Driver via Helm"
  type        = bool
  default     = false
}

variable "enable_efs_csi_driver" {
  description = "Deploy the Amazon EFS CSI Driver via Helm"
  type        = bool
  default     = false
}

variable "enable_secrets_store_csi_driver" {
  description = "Deploy the AWS Secrets Store CSI Driver and AWS Provider via Helm"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
