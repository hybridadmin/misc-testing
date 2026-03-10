# -----------------------------------------------------------------------------
# environments/dev/env.hcl
#
# Environment-level variables for the dev environment.
# Cost-optimized settings with relaxed HA for development workloads.
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "postgres"
  environment = "dev"
  account_id  = "000000000000"   # Replace with your dev account ID

  # Networking -- replace with your actual VPC and subnet IDs
  vpc_id     = "vpc-xxxxxxxxxxxxxxxxx"
  subnet_ids = ["subnet-xxxxxxxxxxxxxxxxx", "subnet-yyyyyyyyyyyyyyyyy"]

  # Engine
  engine_version = "16.1"

  # Instance -- small and cost-effective for dev
  instance_class        = "db.t3.micro"
  allocated_storage     = 20
  max_allocated_storage = 50

  # HA -- disabled for dev
  multi_az = false

  # Backup -- minimal retention for dev
  backup_retention_period = 3
  skip_final_snapshot     = true
  deletion_protection     = false

  # Monitoring -- basic for dev
  monitoring_interval                   = 60
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # Alarms
  create_cloudwatch_alarms = false
  alarm_sns_topic_arns     = []

  # Access
  allowed_cidr_blocks        = ["10.0.0.0/8"]
  allowed_security_group_ids = []

  # Maintenance
  apply_immediately          = true
  auto_minor_version_upgrade = true
}
