# -----------------------------------------------------------------------------
# AWS Health Events Notifications Terraform Module
#
# Deploys a Lambda function that forwards AWS Health events to a Slack
# channel via an incoming webhook URL.
#
# Ported from CloudFormation StackSets template:
#   devops-utilities-notifications/stacksets/template.json
#
# Resources created:
#   - IAM Role for the Lambda function
#   - CloudWatch Log Group for Lambda logs
#   - Lambda Function (Slack notifier)
#   - EventBridge Rule (AWS Health Events -> Lambda)
#   - Lambda Permission for EventBridge invocation
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix   = "${upper(var.project)}-${upper(var.environment)}"
  function_name = "${local.name_prefix}-AWS-HealthEvents"
  rule_name     = "${local.name_prefix}-AWS-Health-Events-Rule"

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
# Package the Lambda source code
# -----------------------------------------------------------------------------

data "archive_file" "lambda" {
  type        = "zip"
  source_file = var.lambda_source_path
  output_path = "${path.module}/../../build/HealthEvents-${md5(file(var.lambda_source_path))}.zip"
}

# -----------------------------------------------------------------------------
# IAM Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  name = "${local.function_name}-${data.aws_region.current.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "lambda_logs" {
  name = "${local.function_name}-logs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaLogGroupAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.lambda.arn,
          "${aws_cloudwatch_log_group.lambda.arn}:log-stream:*",
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "health_events" {
  function_name = local.function_name
  description   = "AWS PHD Slack Notifier - forwards AWS Health events to Slack"
  handler       = "lambda_function.handler"
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout
  architectures = var.lambda_architectures

  role = aws_iam_role.lambda.arn

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      WEBHOOK_URL   = var.slack_webhook_url
      SLACK_CHANNEL = var.slack_channel
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda_logs,
  ]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EventBridge Rule - triggers on AWS Health events
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "health_events" {
  name        = local.rule_name
  description = "Forward AWS Health events to ${local.function_name} Lambda"

  event_pattern = jsonencode({
    source = ["aws.health"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.health_events.name
  arn  = aws_lambda_function.health_events.arn
}

# -----------------------------------------------------------------------------
# Lambda Permission - allow EventBridge to invoke the function
# -----------------------------------------------------------------------------

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health_events.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_events.arn
}
