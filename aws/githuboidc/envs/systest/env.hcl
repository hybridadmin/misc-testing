# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "github-oidc"
  environment = "systest"
  account_id  = "000000000000"

  # GitHub Actions OIDC roles to create in the systest account.
  github_actions_roles = [
    {
      name        = "github-actions-deploy"
      description = "GitHub Actions deployment role for CI/CD pipelines"
      subject_claims = [
        "repo:example-org/example-repo:ref:refs/heads/main",
        "repo:example-org/example-repo:ref:refs/heads/develop",
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
            ]
          })
        },
      ]
    },
  ]
}
