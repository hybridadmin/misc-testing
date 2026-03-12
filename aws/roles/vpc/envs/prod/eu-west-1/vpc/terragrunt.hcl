# -----------------------------------------------------------------------------
# Leaf terragrunt.hcl - prod / eu-west-1
#
# Deploys VPC into the production account in eu-west-1.
# Full HA: one NAT per AZ, ALL traffic flow logs, extended retention.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/vpc.hcl"
  expose = true
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  # Production uses interface endpoints for Secrets Manager to allow
  # database secret rotation without traversing the internet.
  # Uncomment and configure once the region is known:
  #
  # interface_endpoints = {
  #   secretsmanager = {
  #     service_name = "com.amazonaws.eu-west-1.secretsmanager"
  #     private_dns  = true
  #   }
  #   ssm = {
  #     service_name = "com.amazonaws.eu-west-1.ssm"
  #     private_dns  = true
  #   }
  # }
}
