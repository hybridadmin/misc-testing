# -----------------------------------------------------------------------------
# nacl.tf
#
# Network Access Control Lists (NACLs) for each subnet tier.
#
# Security model:
#   - Public subnets:   Allow HTTP/HTTPS inbound from internet, ephemeral ports
#                       for return traffic, all outbound.
#   - Private subnets:  Allow all traffic from VPC CIDR, ephemeral ports from
#                       internet (for NAT return traffic), all outbound.
#   - Database subnets: DENY all internet ingress. Allow ONLY database port
#                       traffic from private subnets. Allow outbound via NAT
#                       for patching, secret rotation, and AWS API access.
# -----------------------------------------------------------------------------

###############################################################################
# Public Subnet NACL
###############################################################################

resource "aws_network_acl" "public" {
  count = var.create_custom_nacls ? 1 : 0

  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.public[*].id

  tags = merge(local.tags, {
    Name = "${local.identifier}-public-nacl"
    Tier = "public"
  })
}

# --- Public NACL: Default Ingress Rules ---

# Allow HTTP from anywhere
resource "aws_network_acl_rule" "public_ingress_http" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

# Allow HTTPS from anywhere
resource "aws_network_acl_rule" "public_ingress_https" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# Allow ephemeral ports for return traffic (NAT, ALB health checks, etc.)
resource "aws_network_acl_rule" "public_ingress_ephemeral" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = 120
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# Allow all traffic from within VPC (inter-subnet communication)
resource "aws_network_acl_rule" "public_ingress_vpc" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = 130
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.cidr_block
  from_port      = 0
  to_port        = 0
}

# Custom ingress rules
resource "aws_network_acl_rule" "public_ingress_custom" {
  count = var.create_custom_nacls ? length(var.public_nacl_ingress_rules) : 0

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = var.public_nacl_ingress_rules[count.index].rule_number
  egress         = false
  protocol       = var.public_nacl_ingress_rules[count.index].protocol
  rule_action    = var.public_nacl_ingress_rules[count.index].rule_action
  cidr_block     = var.public_nacl_ingress_rules[count.index].cidr_block
  from_port      = var.public_nacl_ingress_rules[count.index].from_port
  to_port        = var.public_nacl_ingress_rules[count.index].to_port
}

# --- Public NACL: Default Egress Rules ---

# Allow all outbound
resource "aws_network_acl_rule" "public_egress_all" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# Custom egress rules
resource "aws_network_acl_rule" "public_egress_custom" {
  count = var.create_custom_nacls ? length(var.public_nacl_egress_rules) : 0

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = var.public_nacl_egress_rules[count.index].rule_number
  egress         = true
  protocol       = var.public_nacl_egress_rules[count.index].protocol
  rule_action    = var.public_nacl_egress_rules[count.index].rule_action
  cidr_block     = var.public_nacl_egress_rules[count.index].cidr_block
  from_port      = var.public_nacl_egress_rules[count.index].from_port
  to_port        = var.public_nacl_egress_rules[count.index].to_port
}

###############################################################################
# Private Subnet NACL
###############################################################################

resource "aws_network_acl" "private" {
  count = var.create_custom_nacls ? 1 : 0

  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.private[*].id

  tags = merge(local.tags, {
    Name = "${local.identifier}-private-nacl"
    Tier = "private"
  })
}

# --- Private NACL: Default Ingress Rules ---

# Allow all traffic from VPC CIDR (application-to-application, ALB-to-app, etc.)
resource "aws_network_acl_rule" "private_ingress_vpc" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.cidr_block
  from_port      = 0
  to_port        = 0
}

# Allow ephemeral ports from internet (NAT gateway return traffic)
resource "aws_network_acl_rule" "private_ingress_ephemeral" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# Custom ingress rules
resource "aws_network_acl_rule" "private_ingress_custom" {
  count = var.create_custom_nacls ? length(var.private_nacl_ingress_rules) : 0

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = var.private_nacl_ingress_rules[count.index].rule_number
  egress         = false
  protocol       = var.private_nacl_ingress_rules[count.index].protocol
  rule_action    = var.private_nacl_ingress_rules[count.index].rule_action
  cidr_block     = var.private_nacl_ingress_rules[count.index].cidr_block
  from_port      = var.private_nacl_ingress_rules[count.index].from_port
  to_port        = var.private_nacl_ingress_rules[count.index].to_port
}

# --- Private NACL: Default Egress Rules ---

# Allow all outbound (applications need outbound for APIs, registries, etc.)
resource "aws_network_acl_rule" "private_egress_all" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# Custom egress rules
resource "aws_network_acl_rule" "private_egress_custom" {
  count = var.create_custom_nacls ? length(var.private_nacl_egress_rules) : 0

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = var.private_nacl_egress_rules[count.index].rule_number
  egress         = true
  protocol       = var.private_nacl_egress_rules[count.index].protocol
  rule_action    = var.private_nacl_egress_rules[count.index].rule_action
  cidr_block     = var.private_nacl_egress_rules[count.index].cidr_block
  from_port      = var.private_nacl_egress_rules[count.index].from_port
  to_port        = var.private_nacl_egress_rules[count.index].to_port
}

###############################################################################
# Database Subnet NACL (Most Restrictive)
#
# Ingress: ONLY from private subnet CIDRs on specific database ports.
#          NO internet ingress whatsoever.
# Egress:  HTTPS (443) for AWS API calls (Secrets Manager rotation, RDS patching).
#          Ephemeral ports for return traffic to private subnets.
#          NAT gateway for OS-level updates.
###############################################################################

resource "aws_network_acl" "database" {
  count = var.create_custom_nacls ? 1 : 0

  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.database[*].id

  tags = merge(local.tags, {
    Name = "${local.identifier}-database-nacl"
    Tier = "database"
  })
}

# --- Database NACL: Default Ingress Rules ---

# Allow database ports from each private subnet CIDR
# Rule numbers: 100, 101, 102 for first port * 3 subnets, 110, 111, 112 for second port, etc.
resource "aws_network_acl_rule" "database_ingress_from_private" {
  count = var.create_custom_nacls ? length(var.database_allowed_ports) * 3 : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = 100 + (floor(count.index / 3) * 10) + (count.index % 3)
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.private_subnet_cidrs[count.index % 3]
  from_port      = var.database_allowed_ports[floor(count.index / 3)]
  to_port        = var.database_allowed_ports[floor(count.index / 3)]
}

# Allow ephemeral return traffic from NAT gateway (for outbound connections)
resource "aws_network_acl_rule" "database_ingress_ephemeral" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = 200
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# Custom ingress rules
resource "aws_network_acl_rule" "database_ingress_custom" {
  count = var.create_custom_nacls ? length(var.database_nacl_ingress_rules) : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = var.database_nacl_ingress_rules[count.index].rule_number
  egress         = false
  protocol       = var.database_nacl_ingress_rules[count.index].protocol
  rule_action    = var.database_nacl_ingress_rules[count.index].rule_action
  cidr_block     = var.database_nacl_ingress_rules[count.index].cidr_block
  from_port      = var.database_nacl_ingress_rules[count.index].from_port
  to_port        = var.database_nacl_ingress_rules[count.index].to_port
}

# --- Database NACL: Default Egress Rules ---

# Allow HTTPS outbound for AWS API access (Secrets Manager, RDS patching, etc.)
resource "aws_network_acl_rule" "database_egress_https" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# Allow HTTP outbound (some package managers, OS updates)
resource "aws_network_acl_rule" "database_egress_http" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = 110
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

# Allow ephemeral port responses back to private subnets (query results)
resource "aws_network_acl_rule" "database_egress_ephemeral_to_private" {
  count = var.create_custom_nacls ? 3 : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = 120 + count.index
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.private_subnet_cidrs[count.index]
  from_port      = 1024
  to_port        = 65535
}

# Allow DNS (UDP) for name resolution via VPC DNS
resource "aws_network_acl_rule" "database_egress_dns_udp" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = 130
  egress         = true
  protocol       = "udp"
  rule_action    = "allow"
  cidr_block     = var.cidr_block
  from_port      = 53
  to_port        = 53
}

# Allow DNS (TCP) for large DNS responses
resource "aws_network_acl_rule" "database_egress_dns_tcp" {
  count = var.create_custom_nacls ? 1 : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = 131
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.cidr_block
  from_port      = 53
  to_port        = 53
}

# Custom egress rules
resource "aws_network_acl_rule" "database_egress_custom" {
  count = var.create_custom_nacls ? length(var.database_nacl_egress_rules) : 0

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = var.database_nacl_egress_rules[count.index].rule_number
  egress         = true
  protocol       = var.database_nacl_egress_rules[count.index].protocol
  rule_action    = var.database_nacl_egress_rules[count.index].rule_action
  cidr_block     = var.database_nacl_egress_rules[count.index].cidr_block
  from_port      = var.database_nacl_egress_rules[count.index].from_port
  to_port        = var.database_nacl_egress_rules[count.index].to_port
}
