# -----------------------------------------------------------------------------
# envs/prodire/env.hcl
#
# Environment-level variables for the prodire (Production Ireland) environment.
#
# This deploys GitHub OIDC providers and IAM roles across multiple accounts
# in the specified OUs. Each account in those OUs gets its own leaf
# directory. Use the generate_account_dirs.sh helper or manually add
# account directories under each region.
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "github-oidc"
  environment = "prodire"
  account_id  = "000000000000" # Override per-account in account.hcl

  # GitHub Actions OIDC roles to create in each target account.
  # Adjust subject_claims to match your GitHub org/repo/branch patterns.
  github_actions_roles = [
    {
      name        = "github-actions-deploy"
      description = "GitHub Actions deployment role for CI/CD pipelines"
      subject_claims = [
        "repo:example-org/example-repo:ref:refs/heads/main",
        "repo:example-org/example-repo:ref:refs/heads/release/*",
      ]
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
      ]
      inline_policies = [
        {
          name = "deploy-permissions"
          policy = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Sid    = "AllowS3Deploy"
                Effect = "Allow"
                Action = [
                  "s3:PutObject",
                  "s3:GetObject",
                  "s3:ListBucket",
                ]
                Resource = "*"
              },
              {
                Sid    = "AllowECRPush"
                Effect = "Allow"
                Action = [
                  "ecr:GetAuthorizationToken",
                  "ecr:BatchCheckLayerAvailability",
                  "ecr:PutImage",
                  "ecr:InitiateLayerUpload",
                  "ecr:UploadLayerPart",
                  "ecr:CompleteLayerUpload",
                ]
                Resource = "*"
              },
            ]
          })
        },
      ]
    },
    {
      name        = "github-actions-readonly"
      description = "GitHub Actions read-only role for CI validation"
      subject_claims = [
        "repo:example-org/*:pull_request",
      ]
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
      ]
    },
  ]

  # For reference / documentation - the OUs this should cover
  target_ou_ids = [
    "ou-xxxx-aaaaaaaa", # Production Accounts OU
    "ou-xxxx-bbbbbbbb", # Development Accounts OU
    "ou-xxxx-cccccccc", # Services Accounts OU
  ]

  target_regions = [
    "eu-west-1",
    "af-south-1",
  ]
}
