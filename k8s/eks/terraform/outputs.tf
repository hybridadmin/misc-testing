# -----------------------------------------------------------------------------
# Cluster Outputs
# -----------------------------------------------------------------------------

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = module.eks.cluster_version
}

output "cluster_ca_certificate" {
  description = "Base64 encoded cluster CA certificate"
  value       = module.eks.cluster_ca_certificate
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Network Outputs
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (where pods run)"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (ALB + NAT gateways)"
  value       = module.vpc.public_subnet_ids
}

output "nat_gateway_ips" {
  description = "Elastic IPs of the NAT gateways (egress IPs for pods)"
  value       = module.vpc.nat_gateway_ips
}

# -----------------------------------------------------------------------------
# IRSA Outputs
# -----------------------------------------------------------------------------

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider (use for additional IRSA roles)"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_id" {
  description = "OIDC provider ID (issuer URL without https://)"
  value       = module.eks.oidc_provider_id
}

# -----------------------------------------------------------------------------
# Convenience Outputs
# -----------------------------------------------------------------------------

output "configure_kubectl" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "lb_controller_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller"
  value       = module.addons.lb_controller_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for the Cluster Autoscaler"
  value       = module.addons.cluster_autoscaler_role_arn
}

output "ebs_csi_driver_role_arn" {
  description = "IAM role ARN for the EBS CSI Driver"
  value       = module.eks.ebs_csi_driver_role_arn
}

output "s3_csi_driver_role_arn" {
  description = "IAM role ARN for the Mountpoint for Amazon S3 CSI Driver"
  value       = module.addons.s3_csi_driver_role_arn
}

output "efs_csi_driver_role_arn" {
  description = "IAM role ARN for the Amazon EFS CSI Driver"
  value       = module.addons.efs_csi_driver_role_arn
}

output "secrets_store_role_arn" {
  description = "IAM role ARN for the AWS Secrets Store CSI Driver Provider"
  value       = module.addons.secrets_store_role_arn
}

# -----------------------------------------------------------------------------
# Security Group Outputs
# -----------------------------------------------------------------------------

output "cluster_security_group_id" {
  description = "Security group ID of the EKS cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID of the EKS worker nodes"
  value       = module.eks.node_security_group_id
}
