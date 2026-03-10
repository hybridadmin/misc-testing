# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

variable "project" {
  description = "Project identifier"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. systest, prodire, prodct)"
  type        = string
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
  description = "VPC CIDR block - used for NFS ingress rule"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for EFS mount targets (one per AZ)"
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
