variable "project" {
  description = "Project identifier (lowercase)"
  type        = string
}

variable "environment" {
  description = "Environment identifier (lowercase)"
  type        = string
}

variable "devops_account_id" {
  description = "AWS account ID of the DevOps account"
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

variable "devops_event_bus_arn" {
  description = "ARN of the DevOps account default event bus for forwarding events"
  type        = string
}

variable "sns_topic_name" {
  description = "Name of the SNS topic for backup vault failure notifications"
  type        = string
  default     = "devops-events-general"
}

variable "enable_backup_plan" {
  description = "Whether to create backup plan (disabled in backup_region since copies go there)"
  type        = bool
  default     = true
}

variable "enable_event_forwarding_role" {
  description = "Whether to create the event forwarding IAM role (only in primary region)"
  type        = bool
  default     = false
}

variable "enable_backup_copy_event_forwarding" {
  description = "Whether to forward backup copy events to DevOps account"
  type        = bool
  default     = true
}

variable "enable_ec2_event_forwarding" {
  description = "Whether to forward EC2 image events to DevOps account"
  type        = bool
  default     = true
}

variable "enable_ecr_event_forwarding" {
  description = "Whether to forward ECR image events to DevOps account"
  type        = bool
  default     = true
}

variable "enable_cross_account_role" {
  description = "Whether to create the cross-account backup role for DevOps (only in primary region)"
  type        = bool
  default     = false
}

variable "is_cape_town" {
  description = "Whether this deployment is in af-south-1 (Cape Town) - affects org-level permissions"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
