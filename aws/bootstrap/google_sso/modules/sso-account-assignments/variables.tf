###############################################################################
# Variables — SSO Account Assignments Module
###############################################################################

variable "account_assignments" {
  description = <<-EOT
    List of account assignment mappings. Each entry assigns a principal
    (GROUP or USER) to an AWS account with a specific permission set.

    Fields:
      - account_id:          The target AWS account ID
      - permission_set_name: Name of the permission set (must already exist)
      - principal_type:      Either "GROUP" or "USER"
      - principal_name:      Display name of the group or username of the user
  EOT
  type = list(object({
    account_id          = string
    permission_set_name = string
    principal_type      = string   # "GROUP" or "USER"
    principal_name      = string
  }))

  validation {
    condition = alltrue([
      for a in var.account_assignments : contains(["GROUP", "USER"], a.principal_type)
    ])
    error_message = "principal_type must be either 'GROUP' or 'USER'."
  }

  validation {
    condition = alltrue([
      for a in var.account_assignments : can(regex("^[0-9]{12}$", a.account_id))
    ])
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
