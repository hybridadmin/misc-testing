# -----------------------------------------------------------------------------
# flow_logs.tf
#
# VPC Flow Logs for network traffic monitoring, security analysis, and
# compliance. Supports both CloudWatch Logs and S3 destinations.
# -----------------------------------------------------------------------------

###############################################################################
# CloudWatch Log Group (when destination is cloud-watch-logs)
###############################################################################

resource "aws_cloudwatch_log_group" "flow_log" {
  count = var.enable_flow_logs && var.flow_log_destination_type == "cloud-watch-logs" ? 1 : 0

  name              = "/aws/vpc/flow-logs/${local.identifier}"
  retention_in_days = var.flow_log_retention_in_days
  kms_key_id        = local.flow_log_kms_key_id

  tags = merge(local.tags, {
    Name = "${local.identifier}-flow-logs"
  })
}

###############################################################################
# IAM Role for Flow Logs (CloudWatch destination only)
###############################################################################

data "aws_iam_policy_document" "flow_log_assume" {
  count = var.enable_flow_logs && var.flow_log_destination_type == "cloud-watch-logs" ? 1 : 0

  statement {
    sid     = "AllowFlowLogAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_log" {
  count = var.enable_flow_logs && var.flow_log_destination_type == "cloud-watch-logs" ? 1 : 0

  name               = "${local.identifier}-flow-log"
  assume_role_policy = data.aws_iam_policy_document.flow_log_assume[0].json

  tags = merge(local.tags, {
    Name = "${local.identifier}-flow-log-role"
  })
}

data "aws_iam_policy_document" "flow_log_permissions" {
  count = var.enable_flow_logs && var.flow_log_destination_type == "cloud-watch-logs" ? 1 : 0

  statement {
    sid    = "AllowFlowLogWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_log[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_log" {
  count = var.enable_flow_logs && var.flow_log_destination_type == "cloud-watch-logs" ? 1 : 0

  name   = "${local.identifier}-flow-log"
  role   = aws_iam_role.flow_log[0].id
  policy = data.aws_iam_policy_document.flow_log_permissions[0].json
}

###############################################################################
# VPC Flow Log
###############################################################################

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id = aws_vpc.this.id

  traffic_type             = var.flow_log_traffic_type
  max_aggregation_interval = var.flow_log_max_aggregation_interval

  # Destination configuration
  log_destination_type = var.flow_log_destination_type
  log_destination      = var.flow_log_destination_type == "s3" ? local.flow_log_s3_arn : aws_cloudwatch_log_group.flow_log[0].arn
  iam_role_arn         = var.flow_log_destination_type == "cloud-watch-logs" ? aws_iam_role.flow_log[0].arn : null

  # S3 destination options
  dynamic "destination_options" {
    for_each = var.flow_log_destination_type == "s3" ? [1] : []

    content {
      file_format                = "parquet"
      hive_compatible_partitions = true
      per_hour_partition         = true
    }
  }

  # Custom log format
  log_format = var.flow_log_log_format != "" ? var.flow_log_log_format : null

  tags = merge(local.tags, {
    Name = "${local.identifier}-flow-log"
  })
}
