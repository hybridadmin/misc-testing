###############################################################################
# Master Account — SSO Configuration
#
# This deploys the SSO configuration in the master (management) account.
# It creates the Identity Store groups, users, and memberships that mirror
# your Google Workspace directory.
#
# IMPORTANT: This must be deployed FIRST, before permission sets or
# account assignments.
###############################################################################

include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/sso-configuration.hcl"
  expose = true
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

inputs = {
  # ---------------------------------------------------------------------------
  # SSO Groups
  #
  # These groups should mirror your Google Workspace groups. If using SCIM
  # auto-provisioning, these will be created by Google and you can remove
  # this block (use data sources instead in the assignments module).
  # ---------------------------------------------------------------------------
  sso_groups = [
    {
      name        = "AWS-Admins"
      description = "Full administrator access to all AWS accounts"
    },
    {
      name        = "AWS-Developers"
      description = "Developer access — read/write to dev/staging, read-only to prod"
    },
    {
      name        = "AWS-ReadOnly"
      description = "Read-only access across all AWS accounts"
    },
    {
      name        = "AWS-SecurityAudit"
      description = "Security audit access across all AWS accounts"
    },
    {
      name        = "AWS-Billing"
      description = "Billing and cost management access to the master account"
    },
    {
      name        = "AWS-DevOps"
      description = "DevOps/infrastructure access to all AWS accounts"
    },
  ]

  # ---------------------------------------------------------------------------
  # SSO Users (optional — typically handled by SCIM)
  #
  # Uncomment and populate if you want to pre-create users in Terraform
  # rather than relying on SCIM provisioning from Google Workspace.
  # ---------------------------------------------------------------------------
  # sso_users = [
  #   {
  #     user_name    = "admin@example.com"
  #     display_name = "Admin User"
  #     given_name   = "Admin"
  #     family_name  = "User"
  #     email        = "admin@example.com"
  #   },
  # ]

  # ---------------------------------------------------------------------------
  # Group Memberships (optional — typically handled by SCIM)
  # ---------------------------------------------------------------------------
  # group_memberships = [
  #   {
  #     group_name = "AWS-Admins"
  #     user_name  = "admin@example.com"
  #   },
  # ]
}
