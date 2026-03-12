# -----------------------------------------------------------------------------
# _envcommon/vpc.hcl
#
# Shared Terragrunt configuration for the VPC component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/vpc/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/vpc/modules/vpc"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  # VPC
  cidr_block           = local.env_vars.locals.cidr_block
  enable_dns_support   = try(local.env_vars.locals.enable_dns_support, true)
  enable_dns_hostnames = try(local.env_vars.locals.enable_dns_hostnames, true)

  # Availability Zones
  availability_zones = local.env_vars.locals.availability_zones

  # Subnets
  public_subnet_cidrs   = local.env_vars.locals.public_subnet_cidrs
  private_subnet_cidrs  = local.env_vars.locals.private_subnet_cidrs
  database_subnet_cidrs = local.env_vars.locals.database_subnet_cidrs

  # NAT
  enable_nat_gateway = try(local.env_vars.locals.enable_nat_gateway, true)
  single_nat_gateway = local.env_vars.locals.single_nat_gateway

  # Flow Logs
  enable_flow_logs                  = try(local.env_vars.locals.enable_flow_logs, true)
  flow_log_destination_type         = try(local.env_vars.locals.flow_log_destination_type, "cloud-watch-logs")
  flow_log_traffic_type             = try(local.env_vars.locals.flow_log_traffic_type, "ALL")
  flow_log_retention_in_days        = try(local.env_vars.locals.flow_log_retention_in_days, 30)
  flow_log_max_aggregation_interval = try(local.env_vars.locals.flow_log_max_aggregation_interval, 600)

  # VPC Endpoints
  enable_s3_endpoint       = try(local.env_vars.locals.enable_s3_endpoint, true)
  enable_dynamodb_endpoint = try(local.env_vars.locals.enable_dynamodb_endpoint, true)

  # NACLs
  create_custom_nacls    = try(local.env_vars.locals.create_custom_nacls, true)
  database_allowed_ports = try(local.env_vars.locals.database_allowed_ports, [5432, 3306, 6379])

  # DB Subnet Group
  create_database_subnet_group = try(local.env_vars.locals.create_database_subnet_group, true)
}
