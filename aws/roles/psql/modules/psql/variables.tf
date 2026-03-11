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
  default     = "psql"
}

variable "role_name" {
  description = "Role name used in resource naming (matches the Ansible role_name)"
  type        = string
  default     = "psql"
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

# -----------------------------------------------------------------------------
# EKS / IRSA
# -----------------------------------------------------------------------------

variable "eks_oidc_provider_arn" {
  description = "ARN of the EKS cluster's OIDC provider"
  type        = string
}

variable "eks_oidc_provider_url" {
  description = "URL of the EKS cluster's OIDC provider (e.g. https://oidc.eks.<region>.amazonaws.com/id/<id>)"
  type        = string
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
