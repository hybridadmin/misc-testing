###############################################################################
# Variables — SSO Permission Sets Module
###############################################################################

variable "permission_sets" {
  description = <<-EOT
    List of permission sets to create. Each permission set defines a level of
    access that can be assigned to users/groups for specific AWS accounts.

    Fields:
      - name:                  Unique name for the permission set (appears in SSO portal)
      - description:           Human-readable description
      - session_duration:      Session duration in ISO-8601 format (default: PT4H = 4 hours)
      - relay_state:           (Optional) URL to redirect to after sign-in
      - managed_policy_arns:   List of AWS managed policy ARNs to attach
      - inline_policy:         (Optional) JSON inline policy document
      - customer_managed_policies: (Optional) List of customer managed policies
      - permissions_boundary_managed_policy_arn: (Optional) ARN of managed policy for boundary
      - permissions_boundary_customer_managed_policy: (Optional) Customer managed boundary policy
      - tags:                  (Optional) Additional tags
  EOT
  type = list(object({
    name             = string
    description      = string
    session_duration = optional(string, "PT4H")
    relay_state      = optional(string, null)
    managed_policy_arns = optional(list(string), [])
    inline_policy       = optional(string, null)
    customer_managed_policies = optional(list(object({
      name = string
      path = optional(string, "/")
    })), [])
    permissions_boundary_managed_policy_arn = optional(string, null)
    permissions_boundary_customer_managed_policy = optional(object({
      name = string
      path = optional(string, "/")
    }), null)
    tags = optional(map(string), {})
  }))
  default = []
}

variable "tags" {
  description = "Tags to apply to all permission sets"
  type        = map(string)
  default     = {}
}
