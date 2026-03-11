variable "identity_account_id" {
  description = "AWS account ID of the identity/management account that can assume these roles"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
