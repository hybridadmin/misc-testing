##--------------------------------------------------------------
## General
##--------------------------------------------------------------

variable "project" {
  description = "Project identifier"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. systest, prodire)"
  type        = string
}

variable "service" {
  description = "Service name"
  type        = string
  default     = "github-oidc"
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

##--------------------------------------------------------------
## OIDC Provider
##--------------------------------------------------------------

variable "oidc_client_ids" {
  description = "List of client IDs (audiences) for the OIDC provider. 'sts.amazonaws.com' is required for GitHub Actions."
  type        = list(string)
  default     = ["sts.amazonaws.com"]
}

##--------------------------------------------------------------
## GitHub Actions IAM Roles
##--------------------------------------------------------------

variable "github_actions_roles" {
  description = <<-EOT
    List of IAM roles to create for GitHub Actions OIDC federation.

    Each role object supports:
      - name                 (required) : Role name suffix (prepended with PROJECT-ENVIRONMENT-)
      - description          (optional) : Role description
      - subject_claims       (required) : List of GitHub OIDC subject claim patterns
                                          e.g. "repo:my-org/my-repo:ref:refs/heads/main"
                                               "repo:my-org/my-repo:*"
      - managed_policy_arns  (optional) : List of managed IAM policy ARNs to attach
      - inline_policies      (optional) : List of {name, policy} inline policy objects
      - max_session_duration (optional) : Max session duration in seconds (default: 3600)
  EOT

  type = list(object({
    name                 = string
    description          = optional(string)
    subject_claims       = list(string)
    managed_policy_arns  = optional(list(string), [])
    max_session_duration = optional(number, 3600)
    inline_policies = optional(list(object({
      name   = string
      policy = string
    })), [])
  }))

  default = []
}

##--------------------------------------------------------------
## Tags
##--------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
