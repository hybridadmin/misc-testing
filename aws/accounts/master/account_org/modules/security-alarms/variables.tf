variable "stack_name" {
  description = "Name used for CloudTrail, log group, and resource naming"
  type        = string
  default     = "security-alarms"
}

variable "project_upper" {
  description = "Project name in upper case"
  type        = string
  default     = "SECURITYALARM"
}

variable "environment_upper" {
  description = "Environment name in upper case"
  type        = string
  default     = "PROD"
}

variable "project_lower" {
  description = "Project name in lower case"
  type        = string
  default     = "securityalarm"
}

variable "environment_lower" {
  description = "Environment name in lower case"
  type        = string
  default     = "prod"
}

variable "security_hub_rules" {
  description = "Enable extra CIS Security Hub CloudWatch alarms (CIS 3.4-3.14)"
  type        = bool
  default     = true
}

variable "external_idp" {
  description = "Set to true if Google/Azure/External IdP is used with SSO"
  type        = bool
  default     = false
}

variable "sns_lambda_arn" {
  description = "ARN of a Lambda function to subscribe to the security SNS topic (optional)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
