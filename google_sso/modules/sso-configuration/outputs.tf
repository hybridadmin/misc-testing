###############################################################################
# Outputs — SSO Configuration Module
###############################################################################

output "sso_instance_arn" {
  description = "The ARN of the IAM Identity Center (SSO) instance"
  value       = local.sso_instance_arn
}

output "identity_store_id" {
  description = "The Identity Store ID associated with the SSO instance"
  value       = local.identity_store_id
}

output "management_account_id" {
  description = "The AWS management (master) account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "organization_id" {
  description = "The AWS Organizations ID"
  value       = data.aws_organizations_organization.current.id
}

output "sso_groups" {
  description = "Map of created SSO groups (name => group details)"
  value = {
    for name, group in aws_identitystore_group.groups : name => {
      group_id   = group.group_id
      group_name = group.display_name
    }
  }
}

output "sso_users" {
  description = "Map of created SSO users (user_name => user details)"
  value = {
    for name, user in aws_identitystore_user.users : name => {
      user_id   = user.user_id
      user_name = user.user_name
    }
  }
}

output "sso_start_url" {
  description = "The SSO start URL for users to log in (available after SSO is configured)"
  value       = "https://${tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]}.awsapps.com/start"
}
