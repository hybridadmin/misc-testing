variable "project" {
  description = "Project identifier (lowercase)"
  type        = string
}

variable "environment" {
  description = "Environment identifier (lowercase)"
  type        = string
}

variable "backup_account_id" {
  description = "AWS account ID of the backup/DR account"
  type        = string
}

variable "backup_region" {
  description = "AWS region for backup copies (e.g., us-west-2)"
  type        = string
}

variable "general_notification_topic_arn" {
  description = "ARN of the general notification SNS topic"
  type        = string
}

variable "critical_notification_topic_arn" {
  description = "ARN of the critical notification SNS topic"
  type        = string
}

variable "route53_config" {
  description = "List of account IDs whose Route 53 hosted zones should be backed up"
  type        = list(string)
}

variable "route53_backup_role_arn" {
  description = "ARN of the cross-account backup role for the backup account (Route53 lambda)"
  type        = string
}

variable "organization_arn" {
  description = "AWS Organization ARN for AMI sharing"
  type        = string
}

variable "ami_encryption_kms_key_arn" {
  description = "ARN or alias ARN of the KMS key for AMI encryption in backup region"
  type        = string
}

variable "lambda_zip_path" {
  description = "Path to the pre-built Lambda deployment zip file"
  type        = string
}

variable "lambda_runtime" {
  description = "Lambda runtime"
  type        = string
  default     = "nodejs18.x"
}

variable "lambda_log_retention_days" {
  description = "Number of days to retain Lambda log groups"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
