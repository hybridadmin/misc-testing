###############################################################################
# Master Account Configuration
#
# This is the AWS Organizations management (master) account where
# IAM Identity Center (SSO) is enabled.
###############################################################################

locals {
  account_name   = "master"
  aws_account_id = "111111111111"   # <-- REPLACE with your actual master account ID
  aws_profile    = "master-admin"   # <-- REPLACE with your AWS CLI profile name
}
