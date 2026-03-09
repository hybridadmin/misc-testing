###############################################################################
# Workload Staging Account Configuration
###############################################################################

locals {
  account_name   = "workload-staging"
  aws_account_id = "333333333333"           # <-- REPLACE with your staging account ID
  aws_profile    = "workload-staging-admin"  # <-- REPLACE with your AWS CLI profile name
}
