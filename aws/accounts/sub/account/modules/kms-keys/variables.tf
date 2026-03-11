variable "organization_id" {
  description = "The AWS Organizations ID used to scope key access to all accounts in the organisation."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "The organization_id must be a valid AWS Organizations ID (e.g. o-pfayzcebx5)."
  }
}

variable "alias_name" {
  description = "The alias name for the KMS key (without the 'alias/' prefix)."
  type        = string
  default     = "ami-encryption"
}

variable "key_description" {
  description = "Description of the KMS key."
  type        = string
  default     = "AMI Encryption Key for Shared AMIs"
}

variable "admin_role_name" {
  description = "Name of the IAM role granted key administration permissions."
  type        = string
  default     = "CrossAccountAdminAccess"
}

variable "deletion_window_in_days" {
  description = "Number of days before the key is permanently deleted after destruction. Valid values: 7-30."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "enable_key_rotation" {
  description = "Whether to enable automatic annual rotation of the KMS key material."
  type        = bool
  default     = true
}

variable "tags" {
  description = "A map of tags to apply to all resources."
  type        = map(string)
  default     = {}
}
