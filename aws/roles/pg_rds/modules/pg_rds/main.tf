###############################################################################
# DB Subnet Group
###############################################################################

resource "aws_db_subnet_group" "this" {
  name        = "${local.identifier}-subnet-group"
  description = "Subnet group for ${local.identifier} PostgreSQL RDS"
  subnet_ids  = var.subnet_ids

  tags = merge(local.tags, {
    Name = "${local.identifier}-subnet-group"
  })
}

###############################################################################
# DB Parameter Group
###############################################################################

resource "aws_db_parameter_group" "this" {
  name        = "${local.identifier}-pg"
  family      = local.family
  description = "Parameter group for ${local.identifier} PostgreSQL ${local.major_version}"

  dynamic "parameter" {
    for_each = local.merged_parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = try(parameter.value.apply_method, "immediate")
    }
  }

  tags = merge(local.tags, {
    Name = "${local.identifier}-pg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# CloudWatch Log Groups (created before the instance to control retention/KMS)
###############################################################################

resource "aws_cloudwatch_log_group" "this" {
  for_each = toset(var.enabled_cloudwatch_logs_exports)

  name              = "/aws/rds/instance/${local.identifier}/${each.value}"
  retention_in_days = var.cloudwatch_log_group_retention_in_days
  kms_key_id        = var.cloudwatch_log_group_kms_key_id

  tags = local.tags
}

###############################################################################
# Primary RDS Instance
###############################################################################

resource "aws_db_instance" "this" {
  identifier = local.identifier

  # Engine
  engine               = "postgres"
  engine_version       = var.engine_version
  parameter_group_name = aws_db_parameter_group.this.name

  # Instance
  instance_class = var.instance_class

  # Storage
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = var.storage_type
  iops                  = var.iops
  storage_throughput    = var.storage_throughput
  storage_encrypted     = var.storage_encrypted
  kms_key_id            = local.storage_kms_key_id

  # Database
  db_name  = var.db_name != "" ? var.db_name : null
  port     = var.db_port
  username = var.master_username

  # Password management via Secrets Manager (AWS best practice)
  manage_master_user_password   = var.manage_master_user_password
  master_user_secret_kms_key_id = local.secret_kms_key_id

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = var.publicly_accessible
  multi_az               = var.multi_az
  availability_zone      = var.multi_az ? null : var.availability_zone
  ca_cert_identifier     = var.ca_cert_identifier

  # Backup & Recovery
  backup_retention_period      = var.backup_retention_period
  backup_window                = var.backup_window
  copy_tags_to_snapshot        = var.copy_tags_to_snapshot
  delete_automated_backups     = var.delete_automated_backups
  snapshot_identifier          = var.snapshot_identifier
  final_snapshot_identifier    = var.skip_final_snapshot ? null : local.final_snapshot_identifier
  skip_final_snapshot          = var.skip_final_snapshot

  # Maintenance
  maintenance_window          = var.maintenance_window
  auto_minor_version_upgrade  = var.auto_minor_version_upgrade
  allow_major_version_upgrade = var.allow_major_version_upgrade
  apply_immediately           = var.apply_immediately

  # Monitoring
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.performance_insights_kms_key_id : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? local.monitoring_role_arn : null
  enabled_cloudwatch_logs_exports       = var.enabled_cloudwatch_logs_exports

  # Security
  deletion_protection                 = var.deletion_protection
  iam_database_authentication_enabled = var.iam_database_authentication_enabled

  # Blue/Green deployments
  dynamic "blue_green_update" {
    for_each = var.blue_green_update_enabled ? [1] : []
    content {
      enabled = true
    }
  }

  tags = merge(local.tags, {
    Name = local.identifier
  })

  # Ensure log groups exist before the instance tries to write to them
  depends_on = [
    aws_cloudwatch_log_group.this,
  ]

  lifecycle {
    ignore_changes = [
      final_snapshot_identifier,
    ]
  }
}

###############################################################################
# Read Replicas
###############################################################################

resource "aws_db_instance" "replica" {
  for_each = var.read_replicas

  identifier = "${local.identifier}-replica-${each.key}"

  # Replicate from primary
  replicate_source_db = aws_db_instance.this.identifier

  # Instance -- inherit from primary unless overridden
  instance_class = coalesce(each.value.instance_class, var.instance_class)

  # Storage encryption
  storage_encrypted = each.value.storage_encrypted
  kms_key_id        = each.value.kms_key_id != "" ? each.value.kms_key_id : local.storage_kms_key_id

  # Networking
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = each.value.publicly_accessible
  availability_zone      = each.value.availability_zone

  # Monitoring (inherit from primary)
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.performance_insights_kms_key_id : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? local.monitoring_role_arn : null

  # Parameter group
  parameter_group_name = aws_db_parameter_group.this.name

  # Maintenance
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = var.apply_immediately

  # Replicas don't need backup settings (handled by primary)
  backup_retention_period = 0
  skip_final_snapshot     = true

  tags = merge(local.tags, each.value.tags, {
    Name = "${local.identifier}-replica-${each.key}"
    Role = "replica"
  })
}
