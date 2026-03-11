variable "primary_region" {
  description = "Primary AWS region where the automation IAM role is created"
  type        = string
  default     = "eu-west-1"
}

variable "excluded_regions" {
  description = "Regions where remediation should not be deployed"
  type        = list(string)
  default     = ["af-south-1"]
}

variable "mandatory_tag_key" {
  description = "The mandatory tag key to check on S3 buckets"
  type        = string
  default     = "description"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
