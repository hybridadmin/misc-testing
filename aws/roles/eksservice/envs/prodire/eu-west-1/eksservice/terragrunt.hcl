# -----------------------------------------------------------------------------
# envs/prodire/eu-west-1/eksservice/terragrunt.hcl
#
# Deploys EKS Service IAM Role to prodire in eu-west-1.
#
# For multi-account deployment across OUs, use generate_account_dirs.sh to
# create a directory per target account.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/eksservice.hcl"
  expose = true
}

# Override per-account values as needed
# inputs = {
#   eks_oidc_provider_arn = "arn:aws:iam::<account_id>:oidc-provider/..."
#   eks_oidc_provider_url = "https://oidc.eks.<region>.amazonaws.com/id/..."
#   s3_buckets            = ["my-extra-bucket"]
# }
