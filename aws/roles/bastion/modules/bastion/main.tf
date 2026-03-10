# -----------------------------------------------------------------------------
# Bastion Host Terraform Module
#
# Provisions a bastion host behind an Auto Scaling Group for high availability.
#
# Ported from CloudFormation: template.json
#
# Resources created:
#   - Elastic IP
#   - IAM Role + Instance Profile (SSM, SNS, S3, CloudWatch, Route53, etc.)
#   - Security Group (SSH, Icinga, OpenTelemetry)
#   - Launch Template (IMDSv2, UserData)
#   - CloudWatch Log Groups (8 log groups)
#   - Auto Scaling Group (min/max 1)
#   - CloudWatch Alarm (high CPU)
#   - Cloud Map Service Discovery
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix   = "${upper(var.project)}-${upper(var.environment)}"
  stack_name    = "${local.name_prefix}-BASTION"
  role_name_lc  = "bastion"

  common_tags = {
    project     = lower(var.project)
    environment = lower(var.environment)
    service     = "bastion"
    managed_by  = "terragrunt"
  }
}

# -----------------------------------------------------------------------------
# Elastic IP
# -----------------------------------------------------------------------------

resource "aws_eip" "bastion" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name   = "${local.name_prefix}-BASTION"
    server = "Bastion"
  })
}

# -----------------------------------------------------------------------------
# IAM Role + Instance Profile
# -----------------------------------------------------------------------------

resource "aws_iam_role" "bastion" {
  name = "${local.stack_name}-InstanceRole"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["ec2.amazonaws.com"] }
        Action    = ["sts:AssumeRole"]
      }
    ]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]

  tags = local.common_tags
}

# Standard instance permissions
resource "aws_iam_role_policy" "standard" {
  name = "standard-instance-permissions"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.sns_topic_arns
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${lower(var.project)}-${lower(var.environment)}-*"
      },
      {
        Effect = "Allow"
        Action = ["s3:ListBucket", "s3:GetObject"]
        Resource = [
          var.project_bucket_arn,
          "${var.project_bucket_arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.stack_name}-*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.authorized_users_bucket}/authorized_users/*"
      }
    ]
  })
}

# Bastion-specific permissions
resource "aws_iam_role_policy" "bastion" {
  name = "bastion-instance-permissions"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ec2:AssociateAddress"]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:elastic-ip/${aws_eip.bastion.allocation_id}",
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeAddresses"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/monitoring-${lower(var.environment)}-bastion-credentials",
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/monitoring-${lower(var.environment)}-icinga-config",
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/monitoring-${lower(var.environment)}-opentelemetry-config"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:GetHostedZone",
          "route53:ListHostedZones",
          "route53:GetChange",
          "route53:ListHostedZonesByName"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = [for zone_id in var.route53_zone_ids : "arn:aws:route53:::hostedzone/${zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["servicediscovery:RegisterInstance"]
        Resource = aws_service_discovery_service.bastion.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.stack_name}-InstanceProfile"
  role = aws_iam_role.bastion.name
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "bastion" {
  name_prefix = "${local.stack_name}-"
  description = "Allow SSH access to bastion host."
  vpc_id      = var.vpc_id

  # SSH from VPC CIDR
  ingress {
    description = "Allow internal VPC traffic"
    from_port   = var.ssh_port
    to_port     = var.ssh_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # SSH from VPN servers
  dynamic "ingress" {
    for_each = var.vpn_cidrs
    content {
      description = ingress.value.description
      from_port   = var.ssh_port
      to_port     = var.ssh_port
      protocol    = "tcp"
      cidr_blocks = [ingress.value.cidr]
    }
  }

  # Icinga monitoring ports
  dynamic "ingress" {
    for_each = var.icinga_ips
    content {
      description = "Allow Icinga IP ${ingress.key + 1}"
      from_port   = 5665
      to_port     = 5666
      protocol    = "tcp"
      cidr_blocks = ["${ingress.value}/32"]
    }
  }

  # OpenTelemetry from VPC
  ingress {
    description = "Allow OpenTelemetry traffic from internal VPC"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Default egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.stack_name}-SG"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Launch Template
# -----------------------------------------------------------------------------

resource "aws_launch_template" "bastion" {
  name = local.stack_name

  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.bastion.name
  }

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true
    security_groups             = [aws_security_group.bastion.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = local.stack_name
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = local.stack_name
    })
  }

  user_data = base64encode(join("\n", [
    "export AWS_STACK=${local.stack_name}",
    "export APP_PROJECT=${upper(var.project)}",
    "export APP_ENVIRONMENT=${upper(var.environment)}",
    "export APP_ROLE=BASTION",
    "export AWS_CRITICAL_EVENTS_TOPIC=${var.sns_topic_arns[0]}",
    "export AWS_GENERAL_EVENTS_TOPIC=${length(var.sns_topic_arns) > 1 ? var.sns_topic_arns[1] : var.sns_topic_arns[0]}",
    "export AWS_SERVICE_DISCOVERY_NAMESPACE=${var.service_discovery_namespace_id}",
    "export AWS_SERVICE_DISCOVERY_SERVICE=${aws_service_discovery_service.bastion.id}",
    "export AWS_PROJECT_BUCKET=${var.project_bucket_name}",
    "export AWS_EIP_ID=${aws_eip.bastion.allocation_id}",
    "export APP_EFS_FILE_SYSTEM_ID=${var.efs_filesystem_id}",
    "export APP_EFS_TARGET_DIR=/mnt/data",
    "export APP_GIT_REPO_URL=${var.git_repo_url}",
    "export APP_HOSTED_ZONE_ID=${var.hosted_zone_id}",
  ]))

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------

locals {
  log_groups = [
    "amazon-cloudwatch-agent.log",
    "/var/log/syslog",
    "/var/log/auth.log",
    "/var/log/messages",
    "/var/log/secure",
    "/var/log/binu/instance_init",
    "/var/log/audit/audit.log",
    "/var/log/aide/aide.log",
  ]
}

resource "aws_cloudwatch_log_group" "bastion" {
  for_each = toset(local.log_groups)

  name              = "${local.stack_name}-${each.value}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Auto Scaling Group
# -----------------------------------------------------------------------------

resource "aws_autoscaling_group" "bastion" {
  name                = local.stack_name
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = var.public_subnet_ids

  health_check_grace_period = 120
  termination_policies      = ["ClosestToNextInstanceHour", "OldestInstance"]

  launch_template {
    id      = aws_launch_template.bastion.id
    version = aws_launch_template.bastion.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = local.stack_name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ASG notification for launch/terminate errors
resource "aws_autoscaling_notification" "bastion" {
  count = length(var.sns_topic_arns) > 1 ? 1 : 0

  group_names = [aws_autoscaling_group.bastion.name]

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
  ]

  topic_arn = var.sns_topic_arns[length(var.sns_topic_arns) > 1 ? 1 : 0]
}

# -----------------------------------------------------------------------------
# CloudWatch Alarm - High CPU
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${local.stack_name}-WarnHighCpu"
  alarm_description   = "Warn when CPU utilisation above ${var.cpu_warning_threshold}% for 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_warning_threshold
  unit                = "Percent"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.bastion.name
  }

  alarm_actions = [var.sns_topic_arns[length(var.sns_topic_arns) > 1 ? 1 : 0]]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Service Discovery (Cloud Map)
# -----------------------------------------------------------------------------

resource "aws_service_discovery_service" "bastion" {
  name = "bastion"

  dns_config {
    namespace_id = var.service_discovery_namespace_id

    dns_records {
      ttl  = 300
      type = "A"
    }
  }

  description = "Bastion Internal DNS"
}
