# -----------------------------------------------------------------------------
# environments/dev/env.hcl
#
# Environment-level variables for the dev environment.
# Cost-optimized: single NAT gateway, REJECT-only flow logs, relaxed monitoring.
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "network"
  environment = "dev"
  account_id  = "000000000000" # Replace with your dev account ID

  # ---------------------------------------------------------------------------
  # VPC
  # ---------------------------------------------------------------------------
  cidr_block = "10.0.0.0/16"

  # ---------------------------------------------------------------------------
  # Availability Zones
  # ---------------------------------------------------------------------------
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

  # ---------------------------------------------------------------------------
  # Subnets
  #
  # /20 = 4,094 usable IPs per subnet (12,282 total per tier)
  # Public:   10.0.0.0/20,  10.0.16.0/20,  10.0.32.0/20
  # Private:  10.0.48.0/20, 10.0.64.0/20,  10.0.80.0/20
  # Database: 10.0.96.0/20, 10.0.112.0/20, 10.0.128.0/20
  # ---------------------------------------------------------------------------
  public_subnet_cidrs   = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  private_subnet_cidrs  = ["10.0.48.0/20", "10.0.64.0/20", "10.0.80.0/20"]
  database_subnet_cidrs = ["10.0.96.0/20", "10.0.112.0/20", "10.0.128.0/20"]

  # ---------------------------------------------------------------------------
  # NAT Gateway -- single NAT for cost savings (~$32/month vs ~$96/month)
  # ---------------------------------------------------------------------------
  single_nat_gateway = true

  # ---------------------------------------------------------------------------
  # Flow Logs -- REJECT only in dev to reduce costs
  # ---------------------------------------------------------------------------
  enable_flow_logs                  = true
  flow_log_destination_type         = "cloud-watch-logs"
  flow_log_traffic_type             = "REJECT"
  flow_log_retention_in_days        = 7
  flow_log_max_aggregation_interval = 600

  # ---------------------------------------------------------------------------
  # VPC Endpoints -- gateway endpoints are free, always enable
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
