# -----------------------------------------------------------------------------
# variables.tf
#
# Input variables for the ALB module.
# -----------------------------------------------------------------------------

# --- Common -------------------------------------------------------------------

variable "project" {
  description = "Project identifier."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
}

variable "service" {
  description = "Service name."
  type        = string
}

variable "name" {
  description = "Name for the ALB and related resources. Defaults to project-environment-service."
  type        = string
  default     = ""
}

# --- Networking ---------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID in which to create the ALB and security group."
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the ALB. Use public subnets for internet-facing, private for internal."
  type        = list(string)
}

variable "internal" {
  description = "Whether the ALB is internal (true) or internet-facing (false)."
  type        = bool
  default     = false
}

# --- Ports & TLS --------------------------------------------------------------

variable "http_port" {
  description = "HTTP listener port."
  type        = number
  default     = 80
}

variable "https_port" {
  description = "HTTPS listener port."
  type        = number
  default     = 443
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate for the HTTPS listener."
  type        = string
}

variable "ssl_policy" {
  description = "SSL/TLS negotiation policy for the HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS-1-2-Ext-2018-06"
}

# --- Access Logs --------------------------------------------------------------

variable "enable_access_logs" {
  description = "Whether to enable ALB access logging to S3."
  type        = bool
  default     = true
}

variable "access_logs_bucket" {
  description = "S3 bucket name for ALB access logs. Required when enable_access_logs is true."
  type        = string
  default     = ""
}

variable "access_logs_prefix" {
  description = "S3 key prefix for ALB access logs."
  type        = string
  default     = "alb"
}

# --- Security Group -----------------------------------------------------------

variable "ingress_cidr_blocks" {
  description = "CIDR blocks allowed to reach the ALB on HTTP and HTTPS ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- WAF ----------------------------------------------------------------------

variable "enable_waf" {
  description = "Whether to create a WAFv2 WebACL and associate it with the ALB."
  type        = bool
  default     = false
}

variable "waf_rule_action" {
  description = "Override action for managed WAF rule groups: 'count' (monitor) or 'none' (enforce)."
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "none"], var.waf_rule_action)
    error_message = "waf_rule_action must be 'count' (monitor only) or 'none' (enforce / block)."
  }
}

# --- Logging / Retention ------------------------------------------------------

variable "log_retention_days" {
  description = "Retention in days for WAF CloudWatch log groups."
  type        = number
  default     = 180
}

# --- Tags ---------------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources."
  type        = map(string)
  default     = {}
}
