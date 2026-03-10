# -----------------------------------------------------------------------------
# main.tf
#
# Core VPC resources: VPC, subnets (public, private, database), internet
# gateway, NAT gateways, elastic IPs, route tables, and associations.
# -----------------------------------------------------------------------------

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  enable_dns_support                        = var.enable_dns_support
  enable_dns_hostnames                      = var.enable_dns_hostnames
  instance_tenancy                          = var.instance_tenancy
  enable_network_address_usage_metrics      = var.enable_network_address_usage_metrics

  tags = merge(local.tags, {
    Name = local.identifier
  })
}

# Secondary CIDR blocks for additional address space
resource "aws_vpc_ipv4_cidr_block_association" "this" {
  for_each = toset(var.secondary_cidr_blocks)

  vpc_id     = aws_vpc.this.id
  cidr_block = each.value
}

###############################################################################
# Internet Gateway
###############################################################################

resource "aws_internet_gateway" "this" {
  count = var.create_igw ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.identifier}-igw"
  })
}

###############################################################################
# Public Subnets
###############################################################################

resource "aws_subnet" "public" {
  count = 3

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = var.public_subnet_map_public_ip_on_launch

  tags = merge(local.tags, {
    Name = "${local.identifier}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  })
}

# Public route table -- single table shared by all public subnets
resource "aws_route_table" "public" {
  count = var.create_igw ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.identifier}-public-rt"
    Tier = "public"
  })
}

resource "aws_route" "public_internet" {
  count = var.create_igw ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = var.create_igw ? 3 : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

###############################################################################
# NAT Gateways + Elastic IPs
###############################################################################

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.identifier}-nat-eip-${var.availability_zones[count.index]}"
  })

  # EIP may be in use by NAT GW; create replacement before destroying old one
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, {
    Name = "${local.identifier}-nat-${var.availability_zones[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Private Subnets (Application Tier)
###############################################################################

resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.tags, {
    Name = "${local.identifier}-private-${var.availability_zones[count.index]}"
    Tier = "private"
  })
}

# Private route tables -- one per AZ when using multi-NAT, shared when single NAT
resource "aws_route_table" "private" {
  count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : 3) : 1

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = (var.single_nat_gateway || !var.enable_nat_gateway) ? "${local.identifier}-private-rt" : "${local.identifier}-private-rt-${var.availability_zones[count.index]}"
    Tier = "private"
  })
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : 3) : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = 3

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = (var.single_nat_gateway || !var.enable_nat_gateway) ? aws_route_table.private[0].id : aws_route_table.private[count.index].id
}

###############################################################################
# Database Subnets (Isolated Tier)
###############################################################################

resource "aws_subnet" "database" {
  count = 3

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.tags, {
    Name = "${local.identifier}-database-${var.availability_zones[count.index]}"
    Tier = "database"
  })
}

# Database route tables -- mirrors the private tier routing for NAT egress
# (required for patching, secret rotation, and AWS API calls)
resource "aws_route_table" "database" {
  count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : 3) : 1

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = (var.single_nat_gateway || !var.enable_nat_gateway) ? "${local.identifier}-database-rt" : "${local.identifier}-database-rt-${var.availability_zones[count.index]}"
    Tier = "database"
  })
}

resource "aws_route" "database_nat" {
  count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : 3) : 0

  route_table_id         = aws_route_table.database[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "database" {
  count = 3

  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = (var.single_nat_gateway || !var.enable_nat_gateway) ? aws_route_table.database[0].id : aws_route_table.database[count.index].id
}

###############################################################################
# RDS DB Subnet Group
###############################################################################

resource "aws_db_subnet_group" "this" {
  count = var.create_database_subnet_group ? 1 : 0

  name        = var.database_subnet_group_name != "" ? var.database_subnet_group_name : "${local.identifier}-db"
  description = "Database subnet group for ${local.identifier}"
  subnet_ids  = aws_subnet.database[*].id

  tags = merge(local.tags, {
    Name = var.database_subnet_group_name != "" ? var.database_subnet_group_name : "${local.identifier}-db"
  })
}
