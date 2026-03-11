# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "psql"
  environment = "systest"
  account_id  = "000000000000"

  # EKS OIDC provider - update with values from your EKS cluster
  eks_oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
  eks_oidc_provider_url = "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
}
