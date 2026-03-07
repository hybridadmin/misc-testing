output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC Identity Provider for GitHub"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "oidc_provider_url" {
  description = "URL of the IAM OIDC Identity Provider"
  value       = aws_iam_openid_connect_provider.github.url
}

output "role_arns" {
  description = "Map of role name to ARN for all created GitHub Actions roles"
  value = {
    for name, role in aws_iam_role.github_actions :
    name => role.arn
  }
}

output "role_names" {
  description = "Map of role name to full IAM role name for all created GitHub Actions roles"
  value = {
    for name, role in aws_iam_role.github_actions :
    name => role.name
  }
}
