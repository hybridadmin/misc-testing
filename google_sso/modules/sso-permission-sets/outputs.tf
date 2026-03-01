###############################################################################
# Outputs — SSO Permission Sets Module
###############################################################################

output "permission_sets" {
  description = "Map of permission set name => ARN"
  value = {
    for name, ps in aws_ssoadmin_permission_set.this : name => {
      arn              = ps.arn
      name             = ps.name
      session_duration = ps.session_duration
    }
  }
}

output "permission_set_arns" {
  description = "Map of permission set name => ARN (flat)"
  value = {
    for name, ps in aws_ssoadmin_permission_set.this : name => ps.arn
  }
}

output "sso_instance_arn" {
  description = "The ARN of the IAM Identity Center instance"
  value       = local.sso_instance_arn
}
