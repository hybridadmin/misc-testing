###############################################################################
# Variables — SSO Configuration Module
###############################################################################

# ---------------------------------------------------------------------------
# SSO Groups
# ---------------------------------------------------------------------------

variable "sso_groups" {
  description = <<-EOT
    List of SSO groups to create in IAM Identity Store.
    These should mirror the Google Workspace groups you want to use for
    AWS access. If using SCIM auto-provisioning, you may skip this and
    use data sources to look up SCIM-synced groups instead.
  EOT
  type = list(object({
    name        = string
    description = string
  }))
  default = []
}

# ---------------------------------------------------------------------------
# SSO Users (optional — SCIM usually handles this)
# ---------------------------------------------------------------------------

variable "sso_users" {
  description = <<-EOT
    List of SSO users to pre-create in IAM Identity Store.
    Typically SCIM provisioning from Google Workspace handles user creation,
    but you can pre-create users here if needed.
  EOT
  type = list(object({
    user_name    = string
    display_name = string
    given_name   = string
    family_name  = string
    email        = string
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Group Memberships (optional — SCIM usually handles this)
# ---------------------------------------------------------------------------

variable "group_memberships" {
  description = <<-EOT
    List of group-to-user membership mappings. Each entry assigns a user
    to a group. Both the group and user must be defined in sso_groups and
    sso_users respectively.
  EOT
  type = list(object({
    group_name = string
    user_name  = string
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Tags to apply to all resources created by this module"
  type        = map(string)
  default     = {}
}
