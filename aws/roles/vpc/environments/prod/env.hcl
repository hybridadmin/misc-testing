# -----------------------------------------------------------------------------
# environments/prod/env.hcl
#
# Environment-level variables for the production environment.
# Full high availability: one NAT per AZ, ALL traffic flow logs with extended
# retention, aggressive monitoring.
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "network"
  environment = "prod"
  account_id  = "000000000000" # Replace with your production account ID

  # ---------------------------------------------------------------------------
  # VPC
  # ---------------------------------------------------------------------------
  cidr_block = "10.2.0.0/16"

  # ---------------------------------------------------------------------------
  # Availability Zones
  # ---------------------------------------------------------------------------
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

  # ---------------------------------------------------------------------------
  # Subnets
  # ---------------------------------------------------------------------------
  public_subnet_cidrs   = ["10.2.0.0/20", "10.2.16.0/20", "10.2.32.0/20"]
  private_subnet_cidrs  = ["10.2.48.0/20", "10.2.64.0/20", "10.2.80.0/20"]
  database_subnet_cidrs = ["10.2.96.0/20", "10.2.112.0/20", "10.2.128.0/20"]

  # ---------------------------------------------------------------------------
  # NAT Gateway -- one per AZ for high availability in production
  # If one AZ fails, the other two continue serving traffic independently.
  # ---------------------------------------------------------------------------
  single_nat_gateway = false

  # ---------------------------------------------------------------------------
  # Flow Logs -- capture all traffic with longer retention for compliance
  # ---------------------------------------------------------------------------
  enable_flow_logs                  = true
  flow_log_destination_type         = "cloud-watch-logs"
  flow_log_traffic_type             = "ALL"
  flow_log_retention_in_days        = 90
  flow_log_max_aggregation_interval = 60

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
