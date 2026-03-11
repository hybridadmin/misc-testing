variable "name" {
  description = "Base name used for the backup vault, KMS alias, and S3 bucket prefix."
  type        = string
}

variable "organization_id" {
  description = "The AWS Organizations ID used to scope vault copy access to the organisation."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "The organization_id must be a valid AWS Organizations ID (e.g. o-pfayzcebx5)."
  }
}

variable "backup_source_account_ids" {
  description = "List of AWS account IDs allowed to assume the cross-account backup role and access the KMS key via AWS Backup."
  type        = list(string)

  validation {
    condition     = alltrue([for id in var.backup_source_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "Each backup_source_account_id must be a valid 12-digit AWS account ID."
  }
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic for backup vault event notifications."
  type        = string
}

variable "notification_events" {
  description = "List of backup vault events that trigger SNS notifications."
  type        = list(string)
  default     = ["COPY_JOB_FAILED"]
}

variable "admin_role_name" {
  description = "Name of the IAM role granted KMS key administration permissions."
  type        = string
  default     = "CrossAccountAdminAccess"
}

variable "cross_account_role_name" {
  description = "Name of the IAM role that source accounts assume for cross-account backups."
  type        = string
}

variable "bucket_read_org_paths" {
  description = "List of AWS Organizations paths (e.g. o-xxx/r-xxx/ou-xxx-xxx) allowed read access to the backup S3 bucket."
  type        = list(string)
}

variable "backup_retention_days" {
  description = "Number of days before backup objects in S3 are expired. Applies to both current and noncurrent versions."
  type        = number
  default     = 180

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "backup_retention_days must be at least 1."
  }
}

variable "kms_key_description" {
  description = "Description of the KMS key used for backup encryption."
  type        = string
  default     = "AWS Backup Vault CMK"
}

variable "kms_deletion_window_in_days" {
  description = "Number of days before the KMS key is permanently deleted after destruction. Valid values: 7-30."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_in_days >= 7 && var.kms_deletion_window_in_days <= 30
    error_message = "kms_deletion_window_in_days must be between 7 and 30."
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
