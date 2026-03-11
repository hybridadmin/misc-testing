variable "critical_notifications_email" {
  description = "Email address for critical DevOps notifications"
  type        = string
}

variable "general_notifications_email" {
  description = "Email address for general DevOps notifications"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
