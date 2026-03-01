###############################################################################
# Workload Dev Account Configuration
###############################################################################

locals {
  account_name   = "workload-dev"
  aws_account_id = "222222222222"       # <-- REPLACE with your dev account ID
  aws_profile    = "workload-dev-admin" # <-- REPLACE with your AWS CLI profile name
}
