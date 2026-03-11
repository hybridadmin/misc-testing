variable "backup_services_account_id" {
  description = "AWS account ID for the backup services account"
  type        = string
}

variable "route53_trusted_account_ids" {
  description = "List of AWS account IDs trusted to assume the Route53 access role"
  type        = list(string)
}

variable "hosted_zone_ids" {
  description = "List of Route53 hosted zone IDs the Route53 role can manage"
  type        = list(string)
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
