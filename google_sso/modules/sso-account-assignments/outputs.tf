###############################################################################
# Outputs — SSO Account Assignments Module
###############################################################################

output "account_assignments" {
  description = "Map of account assignment keys to their details"
  value = {
    for key, assignment in aws_ssoadmin_account_assignment.this : key => {
      account_id         = assignment.target_id
      principal_type     = assignment.principal_type
      principal_id       = assignment.principal_id
      permission_set_arn = assignment.permission_set_arn
    }
  }
}

output "sso_instance_arn" {
  description = "The ARN of the IAM Identity Center instance"
  value       = local.sso_instance_arn
}

output "identity_store_id" {
  description = "The Identity Store ID"
  value       = local.identity_store_id
}
