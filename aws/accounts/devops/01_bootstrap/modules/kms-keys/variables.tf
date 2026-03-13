variable "project" {
  description = "Project identifier (lowercase)"
  type        = string
}

variable "environment" {
  description = "Environment name (lowercase)"
  type        = string
}

variable "organization_id" {
  description = "AWS Organization ID for cross-account AMI sharing"
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "Organization ID must match pattern o-[a-z0-9]{10,32}."
  }
}

variable "admin_role_name" {
  description = "Name of the IAM role to grant key administration access"
  type        = string
  default     = "CrossAccountAdminAccess"
}

variable "alias_name" {
  description = "Alias name suffix for the KMS key (will be prefixed with project-environment-)"
  type        = string
  default     = "AmiEncryption"
}

variable "key_description" {
  description = "Description for the KMS key"
  type        = string
  default     = "KMS key for encrypting AMIs shared across the organisation"
}

variable "deletion_window_in_days" {
  description = "Duration in days after which the key is deleted after destruction"
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "Deletion window must be between 7 and 30 days."
  }
}

variable "enable_key_rotation" {
  description = "Whether to enable automatic key rotation"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
