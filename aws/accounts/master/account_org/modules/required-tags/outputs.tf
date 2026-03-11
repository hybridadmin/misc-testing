output "config_rule_arn" {
  description = "ARN of the required tags Config rule"
  value       = aws_config_config_rule.required_tags.arn
}

output "config_rule_id" {
  description = "ID of the required tags Config rule"
  value       = aws_config_config_rule.required_tags.id
}
