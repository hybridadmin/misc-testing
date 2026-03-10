# -----------------------------------------------------------------------------
# outputs.tf
#
# Values exported by the ALB module for consumption by other modules/stacks.
# -----------------------------------------------------------------------------

# --- ALB ----------------------------------------------------------------------

output "alb_id" {
  description = "ID of the Application Load Balancer."
  value       = aws_lb.this.id
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the ALB (for Route 53 alias records)."
  value       = aws_lb.this.zone_id
}

# --- Listeners ----------------------------------------------------------------

output "https_listener_arn" {
  description = "ARN of the HTTPS listener. Use this to attach listener rules from other modules."
  value       = aws_lb_listener.https.arn
}

output "http_listener_arn" {
  description = "ARN of the HTTP listener."
  value       = aws_lb_listener.http.arn
}

# --- Security Group -----------------------------------------------------------

output "security_group_id" {
  description = "ID of the ALB security group."
  value       = aws_security_group.alb.id
}

# --- WAF ----------------------------------------------------------------------

output "waf_web_acl_arn" {
  description = "ARN of the WAFv2 WebACL (empty string if WAF is disabled)."
  value       = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : ""
}

output "waf_web_acl_id" {
  description = "ID of the WAFv2 WebACL (empty string if WAF is disabled)."
  value       = var.enable_waf ? aws_wafv2_web_acl.this[0].id : ""
}
