# -----------------------------------------------------------------------------
# environments/staging/env.hcl
#
# Environment-level variables for the staging environment.
# Mirrors production architecture with moderate cost optimization.
# Single NAT gateway (acceptable downtime during AZ failure for staging).
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "network"
  environment = "staging"
  account_id  = "000000000000" # Replace with your staging account ID

  # ---------------------------------------------------------------------------
  # VPC
  # ---------------------------------------------------------------------------
  cidr_block = "10.1.0.0/16"

  # ---------------------------------------------------------------------------
  # Availability Zones
  # ---------------------------------------------------------------------------
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

  # ---------------------------------------------------------------------------
  # Subnets (same sizing as prod to mirror architecture)
  # ---------------------------------------------------------------------------
  public_subnet_cidrs   = ["10.1.0.0/20", "10.1.16.0/20", "10.1.32.0/20"]
  private_subnet_cidrs  = ["10.1.48.0/20", "10.1.64.0/20", "10.1.80.0/20"]
  database_subnet_cidrs = ["10.1.96.0/20", "10.1.112.0/20", "10.1.128.0/20"]

  # ---------------------------------------------------------------------------
  # NAT Gateway -- single NAT for cost savings in staging
  # ---------------------------------------------------------------------------
  single_nat_gateway = true

  # ---------------------------------------------------------------------------
  # Flow Logs -- capture all traffic for staging validation
  # ---------------------------------------------------------------------------
  enable_flow_logs                  = true
  flow_log_destination_type         = "cloud-watch-logs"
  flow_log_traffic_type             = "ALL"
  flow_log_retention_in_days        = 14
  flow_log_max_aggregation_interval = 600

  # ---------------------------------------------------------------------------
  # VPC Endpoints
  # ---------------------------------------------------------------------------
  enable_s3_endpoint       = true
  enable_dynamodb_endpoint = true

  # ---------------------------------------------------------------------------
  # NACLs
  # ---------------------------------------------------------------------------
  create_custom_nacls    = true
  database_allowed_ports = [5432, 3306, 6379]

  # ---------------------------------------------------------------------------
  # DB Subnet Group
  # ---------------------------------------------------------------------------
  create_database_subnet_group = true
}
