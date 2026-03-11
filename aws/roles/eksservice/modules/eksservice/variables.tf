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
  description = "Service name for the EKS workload"
  type        = string
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

# -----------------------------------------------------------------------------
# EKS / IRSA
# -----------------------------------------------------------------------------

variable "eks_oidc_provider_arn" {
  description = "ARN of the EKS cluster's OIDC provider (e.g. arn:aws:iam::<account>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<id>)"
  type        = string
}

variable "eks_oidc_provider_url" {
  description = "URL of the EKS cluster's OIDC provider (e.g. https://oidc.eks.<region>.amazonaws.com/id/<id>)"
  type        = string
}

# -----------------------------------------------------------------------------
# S3 Buckets
# -----------------------------------------------------------------------------

variable "s3_buckets" {
  description = "List of additional S3 bucket names to grant full access to (beyond the default project bucket)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
