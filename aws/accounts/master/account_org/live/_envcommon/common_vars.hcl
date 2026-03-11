# Common variables for all accounts/regions
# Override these in account-specific or region-specific files.

locals {
  # ---------------------------------------------------------------
  # Organization-wide settings (replace with your actual values)
  # ---------------------------------------------------------------
  organization_id = "o-abc123def4"

  # Central audit account settings
  audit_account_id = "111111111111"

  # Identity / management account (for cross-account role trust)
  identity_account_id = "222222222222"

  # DevOps account (read access to CloudTrail)
  devops_account_id = "333333333333"

  # Account that writes CloudTrail logs
  cloudtrail_write_account_id = "444444444444"

  # Backup services account
  backup_services_account_id = "555555555555"

  # Accounts trusted for Route53 access
  route53_trusted_account_ids = ["666666666666", "777777777777"]

  # Route53 hosted zone IDs
  hosted_zone_ids = ["Z0000000000001", "Z0000000000002"]

  # Central bucket names
  cloudtrail_bucket_name   = "org-cloudtrail-logs"
  config_bucket_name       = "org-awsconfig"
  conformance_bucket_name  = "org-configconforms"

  # Config KMS key ARN (from audit-resources module output)
  config_kms_key_arn = "arn:aws:kms:eu-west-1:111111111111:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

  # Notification emails
  critical_notifications_email = "ops-critical@example.com"
  general_notifications_email  = "ops-general@example.com"

  # Target OU IDs (replace with actual OU IDs)
  ou_security    = "ou-xxxx-aaaaaaaa"
  ou_services    = "ou-xxxx-bbbbbbbb"
  ou_production  = "ou-xxxx-cccccccc"
  ou_development = "ou-xxxx-dddddddd"
  ou_root        = "r-xxxx"
}
