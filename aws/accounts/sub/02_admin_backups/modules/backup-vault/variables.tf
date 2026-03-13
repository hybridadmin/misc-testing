variable "project" {
  description = "Project identifier (lowercase)"
  type        = string
}

variable "environment" {
  description = "Environment identifier (lowercase)"
  type        = string
}

variable "backup_account_id" {
  description = "AWS account ID of the backup/DR account. Used to validate this module is only applied in the correct account."
  type        = string
}

variable "devops_account_id" {
  description = "AWS account ID of the DevOps account that will assume cross-account roles"
  type        = string
}

variable "organization_id" {
  description = "AWS Organization ID for backup vault access policy"
  type        = string
}

variable "production_ou_path" {
  description = "Organization path for S3 bucket policy condition (e.g., o-xxx/r-xxx/ou-xxx)"
  type        = string
}

variable "sns_topic_name" {
  description = "Name of the SNS topic for backup vault failure notifications"
  type        = string
  default     = "devops-events-general"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
