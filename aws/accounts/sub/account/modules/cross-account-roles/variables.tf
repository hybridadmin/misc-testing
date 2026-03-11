variable "trusted_account_id" {
  description = "The AWS account ID that is trusted to assume cross-account roles (the identity/management account)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.trusted_account_id))
    error_message = "The trusted_account_id must be a valid 12-digit AWS account ID."
  }
}

variable "require_mfa" {
  description = "Whether to require MFA for assuming cross-account roles."
  type        = bool
  default     = true
}

variable "admin_role_name" {
  description = "Name of the cross-account admin access IAM role."
  type        = string
  default     = "CrossAccountAdminAccess"
}

variable "read_only_role_name" {
  description = "Name of the cross-account read-only access IAM role."
  type        = string
  default     = "CrossAccountReadAccess"
}

variable "role_path" {
  description = "IAM path for the cross-account roles."
  type        = string
  default     = "/"
}

variable "max_session_duration" {
  description = "Maximum session duration (in seconds) for the cross-account roles. Valid values: 3600-43200."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds."
  }
}

variable "tags" {
  description = "A map of tags to apply to all resources."
  type        = map(string)
  default     = {}
}
