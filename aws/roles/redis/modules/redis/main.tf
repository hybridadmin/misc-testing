# -----------------------------------------------------------------------------
# ElastiCache Valkey Cluster Terraform Module
#
# Provisions an encrypted ElastiCache Valkey replication group with automatic
# failover across availability zones. Valkey is a Redis-compatible engine
# with 20% lower node pricing and no extended support fees.
#
# Resources created:
#   - Security Group (Valkey port 6379 from VPC CIDR)
#   - KMS Key + Alias for at-rest encryption (optional — AWS-managed key used when disabled)
#   - ElastiCache Subnet Group (private subnets)
#   - ElastiCache Parameter Group (Valkey 7.x)
#   - ElastiCache Replication Group (cluster-mode, multi-AZ, encrypted)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${upper(var.project)}-${upper(var.environment)}"
  name_lower  = "${lower(var.project)}-${lower(var.environment)}"

  common_tags = merge(var.tags, {
    project     = lower(var.project)
    environment = lower(var.environment)
    service     = lower(var.service)
    managed_by  = "terragrunt"
  })
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "redis" {
  name_prefix = "${local.name_prefix}-REDIS-"
  description = "${local.name_prefix}-REDIS security group rules."
  vpc_id      = var.vpc_id

  ingress {
    description = "Valkey from local VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-REDIS-security-group"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# KMS Key for at-rest encryption (optional — set use_custom_kms_key = false
# to use the free AWS-managed key instead, saving ~$1/month)
# -----------------------------------------------------------------------------

resource "aws_kms_key" "redis" {
  count = var.use_custom_kms_key ? 1 : 0

  description             = "KMS key for ${local.name_prefix} ElastiCache Valkey encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "key-default-1"
    Statement = [
      {
        Sid    = "Allow administration of the key"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "redis" {
  count = var.use_custom_kms_key ? 1 : 0

  name          = "alias/${local.name_lower}-redis"
  target_key_id = aws_kms_key.redis[0].key_id
}

# -----------------------------------------------------------------------------
# ElastiCache Subnet Group
# -----------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "redis" {
  name        = "${local.name_lower}-redis"
  description = "${local.name_prefix} Valkey subnet group"
  subnet_ids  = var.private_subnet_ids

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# ElastiCache Parameter Group
# -----------------------------------------------------------------------------

resource "aws_elasticache_parameter_group" "redis" {
  name        = "${local.name_lower}-redis"
  family      = var.parameter_family
  description = "${local.name_prefix} Valkey parameter group"

  dynamic "parameter" {
    for_each = var.parameters
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# ElastiCache Replication Group (Valkey cluster)
#
# Creates a Valkey replication group with:
#   - Automatic failover (multi-AZ)
#   - Encryption at rest (KMS) and in transit (TLS)
#   - Configurable replicas per shard for HA
#   - Configurable node type, engine version, and shard count
# -----------------------------------------------------------------------------

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${local.name_lower}-redis"
  description          = "${local.name_prefix} Valkey cluster"

  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  # Cluster mode configuration
  num_node_groups         = var.num_shards
  replicas_per_node_group = var.replicas_per_shard

  # Networking
  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  # Encryption
  at_rest_encryption_enabled = true
  kms_key_id                 = var.use_custom_kms_key ? aws_kms_key.redis[0].arn : null
  transit_encryption_enabled = true

  # High availability
  automatic_failover_enabled = var.num_shards > 1 || var.replicas_per_shard > 0
  multi_az_enabled           = var.replicas_per_shard > 0

  # Parameter group
  parameter_group_name = aws_elasticache_parameter_group.redis.name

  # Maintenance & snapshots
  maintenance_window       = var.maintenance_window
  snapshot_window          = var.snapshot_window
  snapshot_retention_limit = var.snapshot_retention_limit

  # Updates
  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-REDIS"
  })

  lifecycle {
    ignore_changes = [num_node_groups]
  }
}
