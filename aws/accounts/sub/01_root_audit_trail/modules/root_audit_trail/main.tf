# -----------------------------------------------------------------------------
# Root Console Sign-In Audit Trail - Terraform Module
#
# Monitors AWS root user console sign-in activity via CloudTrail events and
# sends notifications to an SNS topic. This is a direct port of the
# CloudFormation template "ROOT-AWS-Console-Sign-In-via-CloudTrail".
#
# Resources created:
#   - SNS Topic for root sign-in notifications
#   - SNS Topic Policy (allows EventBridge to publish)
#   - SNS Email Subscription(s)
#   - EventBridge Rule (matches root console sign-in events from CloudTrail)
#   - EventBridge Target (routes matched events to the SNS topic)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${upper(var.project)}-${upper(var.environment)}"
  topic_name  = "${local.name_prefix}-ROOT-Console-Sign-In-via-CloudTrail"
  rule_name   = "${local.name_prefix}-RootActivityRule"

  common_tags = merge(
    {
      project     = lower(var.project)
      environment = lower(var.environment)
      service     = lower(var.service)
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# SNS Topic - notification target for root sign-in events
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "root_activity" {
  name         = local.topic_name
  display_name = "ROOT-AWS-Console-Sign-In-via-CloudTrail"

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# SNS Topic Policy - allow EventBridge to publish to the topic
# -----------------------------------------------------------------------------

resource "aws_sns_topic_policy" "root_activity" {
  arn = aws_sns_topic.root_activity.arn

  policy = jsonencode({
    Id      = "RootPolicyDocument"
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.root_activity.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SNS Email Subscription(s) - one per email address provided
# -----------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.email_addresses)

  topic_arn = aws_sns_topic.root_activity.arn
  protocol  = "email"
  endpoint  = each.value
}

# -----------------------------------------------------------------------------
# EventBridge Rule - matches root console sign-in events from CloudTrail
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "root_activity" {
  name        = local.rule_name
  description = "Events rule for monitoring root AWS Console Sign In activity"

  event_pattern = jsonencode({
    detail-type = ["AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = {
        type = ["Root"]
      }
    }
  })

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EventBridge Target - route matched events to the SNS topic
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_target" "sns" {
  rule = aws_cloudwatch_event_rule.root_activity.name
  arn  = aws_sns_topic.root_activity.arn

  target_id = "RootActivitySNSTopic"
}
