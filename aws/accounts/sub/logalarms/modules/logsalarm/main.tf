# -----------------------------------------------------------------------------
# LogsAlarm Terraform Module
#
# Deploys a Lambda function that captures log samples from CloudWatch Log
# Groups when metric-filter-based CloudWatch alarms fire, and publishes
# them to the alarm's SNS notification topics.
#
# Resources created:
#   - IAM Role for the Lambda function
#   - CloudWatch Log Group for Lambda logs
#   - Lambda Function
#   - EventBridge Rule (CloudWatch Alarm State Change -> ALARM)
#   - Lambda Permission for EventBridge invocation
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix   = "${upper(var.project)}-${upper(var.environment)}"
  function_name = "${local.name_prefix}-LogsAlarm"
  rule_name     = "${local.name_prefix}-handleLogsAlarm"

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
  output_path = "${path.module}/../../build/LogsAlarm-${md5(file(var.lambda_source_path))}.zip"
}

# -----------------------------------------------------------------------------
# IAM Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  name = "${local.function_name}-role"

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
          "${aws_cloudwatch_log_group.lambda.arn}",
          "${aws_cloudwatch_log_group.lambda.arn}:log-stream:*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_cloudwatch" {
  name = "${local.function_name}-cloudwatch"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchAndLogsReadAccess"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "logs:DescribeMetricFilters",
          "logs:FilterLogEvents",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_sns" {
  name = "${local.function_name}-sns"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SNSPublishAccess"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = "*"
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

resource "aws_lambda_function" "logsalarm" {
  function_name = local.function_name
  description   = "Captures log samples from CloudWatch Log Groups when metric-filter-based alarms fire"
  handler       = "lambda_function.lambda_handler"
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout
  architectures = var.lambda_architectures

  role = aws_iam_role.lambda.arn

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      generalNotificationTopic  = "arn:aws:sns:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:devops-events-general"
      criticalNotificationTopic = "arn:aws:sns:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:devops-events-critical"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda_logs,
    aws_iam_role_policy.lambda_cloudwatch,
    aws_iam_role_policy.lambda_sns,
  ]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EventBridge Rule - triggers on CloudWatch Alarm state change to ALARM
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "alarm_trigger" {
  name        = local.rule_name
  description = "Invoke ${local.function_name} Lambda when a CloudWatch alarm transitions to ALARM state"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.alarm_trigger.name
  arn  = aws_lambda_function.logsalarm.arn
}

# -----------------------------------------------------------------------------
# Lambda Permission - allow EventBridge to invoke the function
# -----------------------------------------------------------------------------

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.logsalarm.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_trigger.arn
}
