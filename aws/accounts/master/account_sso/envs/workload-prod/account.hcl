###############################################################################
# Workload Production Account Configuration
###############################################################################

locals {
  account_name   = "workload-prod"
  aws_account_id = "444444444444"         # <-- REPLACE with your production account ID
  aws_profile    = "workload-prod-admin"  # <-- REPLACE with your AWS CLI profile name
}
