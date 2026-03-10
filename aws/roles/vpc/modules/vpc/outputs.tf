# -----------------------------------------------------------------------------
# outputs.tf
#
# All outputs for downstream module consumption. Organized by resource group.
# -----------------------------------------------------------------------------

###############################################################################
# VPC
###############################################################################

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN of the VPC."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "vpc_secondary_cidr_blocks" {
  description = "Secondary CIDR blocks associated with the VPC."
  value       = [for assoc in aws_vpc_ipv4_cidr_block_association.this : assoc.cidr_block]
}

output "vpc_default_security_group_id" {
  description = "ID of the VPC default security group."
  value       = aws_vpc.this.default_security_group_id
}

output "vpc_default_route_table_id" {
  description = "ID of the VPC default route table."
  value       = aws_vpc.this.default_route_table_id
}

output "vpc_default_network_acl_id" {
  description = "ID of the VPC default network ACL."
  value       = aws_vpc.this.default_network_acl_id
}

###############################################################################
# Internet Gateway
###############################################################################

output "internet_gateway_id" {
  description = "ID of the internet gateway."
  value       = try(aws_internet_gateway.this[0].id, null)
}

output "internet_gateway_arn" {
  description = "ARN of the internet gateway."
  value       = try(aws_internet_gateway.this[0].arn, null)
}

###############################################################################
# Public Subnets
###############################################################################

output "public_subnet_ids" {
  description = "List of public subnet IDs."
  value       = aws_subnet.public[*].id
}

output "public_subnet_arns" {
  description = "List of public subnet ARNs."
  value       = aws_subnet.public[*].arn
}

output "public_subnet_cidrs" {
  description = "List of public subnet CIDR blocks."
  value       = aws_subnet.public[*].cidr_block
}

output "public_route_table_ids" {
  description = "List of public route table IDs."
  value       = aws_route_table.public[*].id
}

###############################################################################
# Private Subnets
###############################################################################

output "private_subnet_ids" {
  description = "List of private (application) subnet IDs."
  value       = aws_subnet.private[*].id
}

output "private_subnet_arns" {
  description = "List of private subnet ARNs."
  value       = aws_subnet.private[*].arn
}

output "private_subnet_cidrs" {
  description = "List of private subnet CIDR blocks."
  value       = aws_subnet.private[*].cidr_block
}

output "private_route_table_ids" {
  description = "List of private route table IDs."
  value       = aws_route_table.private[*].id
}

###############################################################################
# Database Subnets
###############################################################################

output "database_subnet_ids" {
  description = "List of database (isolated) subnet IDs."
  value       = aws_subnet.database[*].id
}

output "database_subnet_arns" {
  description = "List of database subnet ARNs."
  value       = aws_subnet.database[*].arn
}

output "database_subnet_cidrs" {
  description = "List of database subnet CIDR blocks."
  value       = aws_subnet.database[*].cidr_block
}

output "database_route_table_ids" {
  description = "List of database route table IDs."
  value       = aws_route_table.database[*].id
}

output "database_subnet_group_name" {
  description = "Name of the RDS DB subnet group."
  value       = try(aws_db_subnet_group.this[0].name, null)
}

output "database_subnet_group_arn" {
  description = "ARN of the RDS DB subnet group."
  value       = try(aws_db_subnet_group.this[0].arn, null)
}

###############################################################################
# NAT Gateways
###############################################################################

output "nat_gateway_ids" {
  description = "List of NAT gateway IDs."
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_public_ips" {
  description = "List of NAT gateway public (Elastic) IP addresses."
  value       = aws_eip.nat[*].public_ip
}

output "nat_gateway_allocation_ids" {
  description = "List of Elastic IP allocation IDs used by NAT gateways."
  value       = aws_eip.nat[*].allocation_id
}

###############################################################################
# Network ACLs
###############################################################################

output "public_nacl_id" {
  description = "ID of the public subnet network ACL."
  value       = try(aws_network_acl.public[0].id, null)
}

output "private_nacl_id" {
  description = "ID of the private subnet network ACL."
  value       = try(aws_network_acl.private[0].id, null)
}

output "database_nacl_id" {
  description = "ID of the database subnet network ACL."
  value       = try(aws_network_acl.database[0].id, null)
}

###############################################################################
# Flow Logs
###############################################################################

output "flow_log_id" {
  description = "ID of the VPC flow log."
  value       = try(aws_flow_log.this[0].id, null)
}

output "flow_log_cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group for VPC flow logs."
  value       = try(aws_cloudwatch_log_group.flow_log[0].arn, null)
}

output "flow_log_iam_role_arn" {
  description = "ARN of the IAM role used by VPC flow logs."
  value       = try(aws_iam_role.flow_log[0].arn, null)
}

###############################################################################
# VPC Endpoints
###############################################################################

output "s3_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "dynamodb_endpoint_id" {
  description = "ID of the DynamoDB gateway VPC endpoint."
  value       = try(aws_vpc_endpoint.dynamodb[0].id, null)
}

output "interface_endpoint_ids" {
  description = "Map of interface endpoint names to their IDs."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "interface_endpoint_dns_entries" {
  description = "Map of interface endpoint names to their DNS entries."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.dns_entry }
}

output "interface_endpoint_security_group_id" {
  description = "ID of the security group attached to interface VPC endpoints."
  value       = try(aws_security_group.interface_endpoints[0].id, null)
}

###############################################################################
# Availability Zones
###############################################################################

output "availability_zones" {
  description = "List of availability zones used by the VPC subnets."
  value       = var.availability_zones
}

###############################################################################
# Convenience Composite Output
###############################################################################

output "network_info" {
  description = "Convenience map of core networking identifiers for downstream modules."
  value = {
    vpc_id               = aws_vpc.this.id
    vpc_cidr             = aws_vpc.this.cidr_block
    public_subnet_ids    = aws_subnet.public[*].id
    private_subnet_ids   = aws_subnet.private[*].id
    database_subnet_ids  = aws_subnet.database[*].id
    db_subnet_group_name = try(aws_db_subnet_group.this[0].name, null)
    nat_gateway_ips      = aws_eip.nat[*].public_ip
    availability_zones   = var.availability_zones
    internet_gateway_id  = try(aws_internet_gateway.this[0].id, null)
  }
}
