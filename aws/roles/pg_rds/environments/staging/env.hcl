# -----------------------------------------------------------------------------
# environments/staging/env.hcl
#
# Environment-level variables for the staging environment.
# Mirrors production configuration at reduced scale for pre-release validation.
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "postgres"
  environment = "staging"
  account_id  = "111111111111"   # Replace with your staging account ID

  # Networking -- replace with your actual VPC and subnet IDs
  vpc_id     = "vpc-xxxxxxxxxxxxxxxxx"
  subnet_ids = ["subnet-xxxxxxxxxxxxxxxxx", "subnet-yyyyyyyyyyyyyyyyy"]

  # Engine
  engine_version = "16.1"

  # Instance -- moderate size for staging
  instance_class        = "db.t3.medium"
  allocated_storage     = 50
  max_allocated_storage = 200

  # HA -- enabled to validate multi-AZ behavior before prod
  multi_az = true

  # Backup
  backup_retention_period = 7
  skip_final_snapshot     = false
  deletion_protection     = true

  # Monitoring
  monitoring_interval                   = 30
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # Alarms
  create_cloudwatch_alarms = true
  alarm_sns_topic_arns     = []   # Add your staging SNS topic ARN

  # Access
  allowed_cidr_blocks        = ["10.0.0.0/8"]
  allowed_security_group_ids = []

  # Maintenance
  apply_immediately          = false
  auto_minor_version_upgrade = true
}
