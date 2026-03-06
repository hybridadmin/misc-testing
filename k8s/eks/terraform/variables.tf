# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Name of the project, used as a prefix for all resources"
  type        = string
  default     = "eks-cluster"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.project_name))
    error_message = "Project name must be lowercase alphanumeric with hyphens, 3-30 characters."
  }
}

variable "environment" {
  description = "Environment name -- must be provided via -var-file (no default)"
  type        = string

  validation {
    condition     = contains(["systest", "prod"], var.environment)
    error_message = "Environment must be one of: systest, prod."
  }
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to deploy into (minimum 2 for EKS)"
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ, pods run here)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ, ALB + NAT gateways here)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway instead of one per AZ (cost savings for non-prod)"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Number of days to retain VPC flow logs in CloudWatch"
  type        = number
  default     = 30
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server endpoint is publicly accessible"
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Whether the EKS API server endpoint is accessible from within the VPC"
  type        = bool
  default     = true
}

variable "cluster_enabled_log_types" {
  description = "List of EKS control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "Number of days to retain EKS control plane logs in CloudWatch"
  type        = number
  default     = 30
}

# -----------------------------------------------------------------------------
# Node Groups
# -----------------------------------------------------------------------------

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_disk_size" {
  description = "Disk size in GiB for worker nodes"
  type        = number
  default     = 50
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes (autoscaler lower bound)"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes (autoscaler upper bound)"
  type        = number
  default     = 5
}

variable "node_capacity_type" {
  description = "Capacity type for nodes: ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "Capacity type must be ON_DEMAND or SPOT."
  }
}

# -----------------------------------------------------------------------------
# Add-ons & Features
# -----------------------------------------------------------------------------

variable "enable_cluster_autoscaler" {
  description = "Deploy Cluster Autoscaler via Helm"
  type        = bool
  default     = true
}

variable "enable_aws_lb_controller" {
  description = "Deploy AWS Load Balancer Controller via Helm for ALB ingress"
  type        = bool
  default     = true
}

variable "enable_metrics_server" {
  description = "Deploy Metrics Server (required for HPA)"
  type        = bool
  default     = true
}

variable "enable_ebs_csi_driver" {
  description = "Deploy the Amazon EBS CSI Driver as an EKS managed add-on"
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

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
