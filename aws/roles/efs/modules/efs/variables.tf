# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

variable "project" {
  description = "Project identifier"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. systest, prodire)"
  type        = string
}

variable "service" {
  description = "Service identifier"
  type        = string
  default     = "efs"
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID where the EFS security group will be created"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block - used for NFS ingress rule on port 2049"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EFS mount targets (one per AZ)"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
