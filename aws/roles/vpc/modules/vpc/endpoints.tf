# -----------------------------------------------------------------------------
# endpoints.tf
#
# VPC Endpoints for cost optimization and security.
#
# Gateway endpoints (S3, DynamoDB):
#   - Free to use -- no hourly or data processing charges.
#   - Traffic stays on the AWS backbone instead of traversing NAT gateways.
#   - Saves ~$0.045/GB in NAT gateway data processing charges.
#
# Interface endpoints (Secrets Manager, SSM, ECR, etc.):
#   - ~$7.20/month per AZ per endpoint + $0.01/GB data processed.
#   - Useful when you need private connectivity without NAT or when
#     security requirements mandate no internet-routable traffic.
# -----------------------------------------------------------------------------

###############################################################################
# Gateway Endpoint - S3
###############################################################################

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id       = aws_vpc.this.id
  service_name = "com.amazonaws.${local.region}.s3"

  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.private[*].id,
    aws_route_table.database[*].id,
    var.create_igw ? aws_route_table.public[*].id : [],
  )

  tags = merge(local.tags, {
    Name = "${local.identifier}-s3-endpoint"
  })
}

###############################################################################
# Gateway Endpoint - DynamoDB
###############################################################################

resource "aws_vpc_endpoint" "dynamodb" {
  count = var.enable_dynamodb_endpoint ? 1 : 0

  vpc_id       = aws_vpc.this.id
  service_name = "com.amazonaws.${local.region}.dynamodb"

  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.private[*].id,
    aws_route_table.database[*].id,
    var.create_igw ? aws_route_table.public[*].id : [],
  )

  tags = merge(local.tags, {
    Name = "${local.identifier}-dynamodb-endpoint"
  })
}

###############################################################################
# Security Group for Interface Endpoints
###############################################################################

resource "aws_security_group" "interface_endpoints" {
  count = length(var.interface_endpoints) > 0 ? 1 : 0

  name_prefix = "${local.identifier}-vpce-"
  description = "Security group for VPC interface endpoints - allows HTTPS from VPC CIDR"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.identifier}-vpce-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow HTTPS inbound from VPC CIDR
resource "aws_vpc_security_group_ingress_rule" "interface_endpoints_https" {
  count = length(var.interface_endpoints) > 0 ? 1 : 0

  security_group_id = aws_security_group.interface_endpoints[0].id
  description       = "HTTPS from VPC CIDR"
  cidr_ipv4         = var.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Allow HTTPS from secondary CIDRs
resource "aws_vpc_security_group_ingress_rule" "interface_endpoints_https_secondary" {
  for_each = length(var.interface_endpoints) > 0 ? toset(var.secondary_cidr_blocks) : toset([])

  security_group_id = aws_security_group.interface_endpoints[0].id
  description       = "HTTPS from secondary CIDR ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

###############################################################################
# Interface Endpoints
###############################################################################

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id            = aws_vpc.this.id
  service_name      = each.value.service_name
  vpc_endpoint_type = "Interface"

  subnet_ids = aws_subnet.private[*].id

  security_group_ids = concat(
    [aws_security_group.interface_endpoints[0].id],
    var.interface_endpoint_security_group_ids,
  )

  private_dns_enabled = each.value.private_dns
  policy              = each.value.policy

  tags = merge(local.tags, {
    Name = "${local.identifier}-${each.key}-endpoint"
  })
}
