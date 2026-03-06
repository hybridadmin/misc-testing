# -----------------------------------------------------------------------------
# Root Module
# Orchestrates VPC, EKS, and add-on modules to deploy a production-ready
# EKS cluster with autoscaling, ALB ingress, and NAT gateway egress.
# -----------------------------------------------------------------------------

locals {
  cluster_name = "${var.project_name}-${var.environment}"

  common_tags = merge(var.additional_tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

module "vpc" {
  source = "./modules/vpc"

  name                 = local.cluster_name
  cluster_name         = local.cluster_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway      = var.single_nat_gateway
  flow_log_retention_days = var.flow_log_retention_days

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EKS Cluster + Node Groups
# -----------------------------------------------------------------------------

module "eks" {
  source = "./modules/eks"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version
  environment     = var.environment

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = var.cluster_endpoint_private_access
  cluster_enabled_log_types       = var.cluster_enabled_log_types
  cluster_log_retention_days      = var.cluster_log_retention_days

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_disk_size      = var.node_disk_size
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  enable_ebs_csi_driver = var.enable_ebs_csi_driver

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Kubernetes Add-ons (ALB Controller, Cluster Autoscaler, Metrics Server,
# S3/EFS/Secrets Store CSI Drivers)
# -----------------------------------------------------------------------------

module "addons" {
  source = "./modules/addons"

  cluster_name      = module.eks.cluster_name
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_id  = module.eks.oidc_provider_id

  enable_aws_lb_controller        = var.enable_aws_lb_controller
  enable_cluster_autoscaler       = var.enable_cluster_autoscaler
  enable_metrics_server           = var.enable_metrics_server
  enable_s3_csi_driver            = var.enable_s3_csi_driver
  enable_efs_csi_driver           = var.enable_efs_csi_driver
  enable_secrets_store_csi_driver = var.enable_secrets_store_csi_driver

  tags = local.common_tags
}
