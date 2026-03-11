# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

variable "project" {
  description = "Project identifier"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. systest, prodire)"
  type        = string
}

variable "service" {
  description = "Service identifier"
  type        = string
  default     = "statics"
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

# -----------------------------------------------------------------------------
# SNS
# -----------------------------------------------------------------------------

variable "sns_to_email_lambda_arn" {
  description = "ARN of the SNS-to-Email Lambda function to subscribe to the SNS topics. Leave empty to skip subscriptions."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# S3 Logs Bucket
# -----------------------------------------------------------------------------

variable "logs_expiration_days" {
  description = "Number of days before log objects expire in the logs bucket"
  type        = number
  default     = 180
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
