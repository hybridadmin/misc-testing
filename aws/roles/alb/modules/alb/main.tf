# -----------------------------------------------------------------------------
# main.tf
#
# Application Load Balancer with optional WAFv2 WebACL.
#
# Ported from the CloudFormation template at:
#   devops-reference-infrastructure/roles/alb/files/template.json
#
# Resources created:
#   - Security Group (HTTP + HTTPS ingress)
#   - Application Load Balancer
#   - HTTPS Listener (default: 404 fixed response)
#   - HTTP  Listener (default: 301 redirect to HTTPS)
#   - [Optional] WAFv2 WebACL with AWS Managed Rule Groups
#   - [Optional] CloudWatch Log Groups for each WAF rule set
# -----------------------------------------------------------------------------

locals {
  name = var.name != "" ? var.name : "${var.project}-${var.environment}-${var.service}"

  common_tags = merge(
    {
      project     = var.project
      environment = var.environment
      service     = var.service
      managed_by  = "terraform"
    },
    var.tags,
  )

  # WAF managed rule groups to attach when WAF is enabled.
  # Each entry maps to an AWS Managed Rule Group with its own log group.
  waf_managed_rules = [
    {
      name     = "AWSManagedRulesCommonRuleSet"
      priority = 0
    },
    {
      name     = "AWSManagedRulesKnownBadInputsRuleSet"
      priority = 1
    },
    {
      name     = "AWSManagedRulesLinuxRuleSet"
      priority = 3
    },
    {
      name     = "AWSManagedRulesAnonymousIpList"
      priority = 5
    },
    {
      name     = "AWSManagedRulesBotControlRuleSet"
      priority = 6
    },
  ]
}

# =============================================================================
# Security Group
# =============================================================================

resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "Allow HTTP & HTTPS access to ALB."
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP"
  ip_protocol       = "tcp"
  from_port         = var.http_port
  to_port           = var.http_port
  cidr_ipv4         = "0.0.0.0/0"

  tags = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS"
  ip_protocol       = "tcp"
  from_port         = var.https_port
  to_port           = var.https_port
  cidr_ipv4         = "0.0.0.0/0"

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = local.common_tags
}

# =============================================================================
# Application Load Balancer
# =============================================================================

resource "aws_lb" "this" {
  name               = local.name
  internal           = var.internal
  load_balancer_type = "application"
  ip_address_type    = "ipv4"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids

  dynamic "access_logs" {
    for_each = var.enable_access_logs ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      prefix  = var.access_logs_prefix
      enabled = true
    }
  }

  tags = merge(local.common_tags, { Name = local.name })
}

# =============================================================================
# HTTPS Listener -- default action: 404 fixed response
# =============================================================================

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.https_port
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
      message_body = "Unknown Page"
    }
  }

  tags = local.common_tags
}

# =============================================================================
# HTTP Listener -- default action: 301 redirect to HTTPS
# =============================================================================

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.http_port
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      host        = "#{host}"
      port        = "443"
      path        = "/#{path}"
      query       = "#{query}"
      status_code = "HTTP_301"
    }
  }

  tags = local.common_tags
}

# =============================================================================
# WAFv2 -- CloudWatch Log Groups (one per managed rule + one general)
# =============================================================================

resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_waf ? 1 : 0

  name              = "${local.name}-WAF"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "waf_rules" {
  for_each = var.enable_waf ? { for r in local.waf_managed_rules : r.name => r } : {}

  name              = "${local.name}-WAF-${each.key}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# =============================================================================
# WAFv2 -- WebACL
# =============================================================================

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  name        = "${local.name}-WAF"
  scope       = "REGIONAL"
  description = "WAF rules for ${local.name}"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-WAF"
    sampled_requests_enabled   = true
  }

  dynamic "rule" {
    for_each = local.waf_managed_rules
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "count" {
          for_each = var.waf_rule_action == "count" ? [1] : []
          content {}
        }
        dynamic "none" {
          for_each = var.waf_rule_action == "none" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-WAF-${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  tags = local.common_tags
}

# =============================================================================
# WAFv2 -- Associate WebACL with the ALB
# =============================================================================

resource "aws_wafv2_web_acl_association" "this" {
  count = var.enable_waf ? 1 : 0

  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
  resource_arn = aws_lb.this.arn
}
