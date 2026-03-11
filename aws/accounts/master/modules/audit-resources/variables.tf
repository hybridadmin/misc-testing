variable "organization_id" {
  description = "AWS Organization ID (e.g. o-xxxxxxxxxx)"
  type        = string
}

variable "admin_role_name" {
  description = "Name of the admin IAM role for KMS key administration"
  type        = string
  default     = "CrossAccountAdminAccess"
}

variable "cloudtrail_bucket_name" {
  description = "Name for the central CloudTrail S3 bucket"
  type        = string
}

variable "config_bucket_name" {
  description = "Name for the central Config S3 bucket"
  type        = string
}

variable "conformance_bucket_name" {
  description = "Name for the Config Conformance Pack S3 bucket"
  type        = string
}

variable "cloudtrail_write_account_id" {
  description = "AWS account ID permitted to write CloudTrail logs to the bucket"
  type        = string
}

variable "devops_account_id" {
  description = "AWS account ID for DevOps with read access to CloudTrail bucket"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
