variable "qualifier" {
  description = "Identifier to distinguish multiple bootstrap stacks in the same environment"
  type        = string
  default     = "hnb659fds"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,10}$", var.qualifier))
    error_message = "Qualifier must be alphanumeric (with hyphens/underscores) and at most 10 characters."
  }
}

variable "trusted_accounts" {
  description = "List of AWS account IDs trusted to publish assets and deploy stacks"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.trusted_accounts : can(regex("^\\d{12}$", id))])
    error_message = "All trusted account IDs must be exactly 12 digits."
  }
}

variable "trusted_accounts_for_lookup" {
  description = "List of AWS account IDs trusted to look up values in this environment"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.trusted_accounts_for_lookup : can(regex("^\\d{12}$", id))])
    error_message = "All account IDs must be exactly 12 digits."
  }
}

variable "cloudformation_execution_policies" {
  description = "List of managed policy ARNs for the CloudFormation execution role. Defaults to AdministratorAccess if empty."
  type        = list(string)
  default     = []
}

variable "file_assets_bucket_name" {
  description = "Custom S3 bucket name for file assets. Leave empty for auto-generated name."
  type        = string
  default     = ""
}

variable "file_assets_bucket_kms_key_id" {
  description = "KMS key ID for the assets bucket. Empty = new key, 'AWS_MANAGED_KEY' = S3 managed key, or provide existing key ARN."
  type        = string
  default     = ""
}

variable "container_assets_repository_name" {
  description = "Custom ECR repository name. Leave empty for auto-generated name."
  type        = string
  default     = ""
}

variable "enable_public_access_block" {
  description = "Whether to enable S3 public access block on the staging bucket"
  type        = bool
  default     = true
}

variable "bootstrap_version" {
  description = "CDK bootstrap version number"
  type        = string
  default     = "21"
}

variable "enable_ecr_image_scanning" {
  description = "Enable image scanning on push for the ECR repository"
  type        = bool
  default     = true
}

variable "enable_bucket_versioning" {
  description = "Enable versioning on the staging bucket"
  type        = bool
  default     = true
}

variable "kms_key_deletion_window" {
  description = "Deletion window in days for the KMS key"
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window >= 7 && var.kms_key_deletion_window <= 30
    error_message = "Deletion window must be between 7 and 30 days."
  }
}

variable "enable_kms_key_rotation" {
  description = "Whether to enable automatic KMS key rotation"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
