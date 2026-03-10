###############################################################################
# Security Group for RDS
###############################################################################

resource "aws_security_group" "this" {
  name        = "${local.identifier}-rds-sg"
  description = "Security group for ${local.identifier} PostgreSQL RDS"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, {
    Name = "${local.identifier}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Ingress Rules -- CIDR blocks
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "cidr" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL access from ${each.value}"
  from_port         = var.db_port
  to_port           = var.db_port
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value

  tags = merge(local.tags, {
    Name = "${local.identifier}-cidr-${each.key}"
  })
}

###############################################################################
# Ingress Rules -- Security groups
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "sg" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL access from sg ${each.value}"
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = each.value

  tags = merge(local.tags, {
    Name = "${local.identifier}-sg-${each.key}"
  })
}

###############################################################################
# Egress -- allow all outbound (required for RDS to reach AWS services)
###############################################################################

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(local.tags, {
    Name = "${local.identifier}-egress-all"
  })
}
