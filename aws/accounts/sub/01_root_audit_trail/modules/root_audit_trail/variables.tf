##--------------------------------------------------------------
## General
##--------------------------------------------------------------

variable "project" {
  description = "Project identifier"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. systest, prodire)"
  type        = string
}

variable "service" {
  description = "Service name"
  type        = string
  default     = "root-audit-trail"
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

##--------------------------------------------------------------
## Notification
##--------------------------------------------------------------

variable "email_addresses" {
  description = "List of email addresses to subscribe to the root sign-in SNS topic"
  type        = list(string)
  validation {
    condition     = length(var.email_addresses) > 0
    error_message = "At least one email address must be provided."
  }
}

##--------------------------------------------------------------
## Tags
##--------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
