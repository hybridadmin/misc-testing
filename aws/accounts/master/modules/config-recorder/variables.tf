variable "config_s3_bucket_name" {
  description = "S3 bucket name for Config delivery"
  type        = string
}

variable "config_kms_key_arn" {
  description = "KMS key ARN for encrypting Config delivery"
  type        = string
}

variable "config_s3_key_prefix" {
  description = "S3 key prefix for Config delivery (optional)"
  type        = string
  default     = ""
}
