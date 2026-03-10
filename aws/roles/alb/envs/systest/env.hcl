# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest (system test) environment.
# Deployed to a single account. No multi-account scaffolding needed.
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "alb"
  environment = "systest"
  account_id  = "000000000000"   # Replace with your systest account ID

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------
  vpc_id     = "vpc-0123456789abcdef0"   # Replace with actual VPC ID
  subnet_ids = [                          # Replace with actual public subnet IDs
    "subnet-0aaa000000000000a",
    "subnet-0bbb000000000000b",
  ]
  internal = false

  # ---------------------------------------------------------------------------
  # TLS
  # ---------------------------------------------------------------------------
  certificate_arn = "arn:aws:acm:eu-west-1:000000000000:certificate/00000000-0000-0000-0000-000000000000"

  # ---------------------------------------------------------------------------
  # Access Logs
  # ---------------------------------------------------------------------------
  enable_access_logs = true
  access_logs_bucket = "myproject-systest-logs-000000000000"
  access_logs_prefix = "alb"

  # ---------------------------------------------------------------------------
  # WAF -- disabled in systest to save costs
  # ---------------------------------------------------------------------------
  enable_waf = false

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------
  log_retention_days = 30
}
