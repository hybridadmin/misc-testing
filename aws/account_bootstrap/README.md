# Cross-Account IAM Roles -- Multi-Account Deployment

Terraform module + Terragrunt live configuration for deploying cross-account IAM roles across an AWS Organization. This is a conversion of the `cross-account-roles.yml` CloudFormation StackSet.

## What Gets Deployed

Two IAM roles are created in each target account:

| Role | Managed Policy | Inline Policy |
|---|---|---|
| `CrossAccountAdminAccess` | `AdministratorAccess` | -- |
| `CrossAccountReadAccess` | `ReadOnlyAccess` | Denies `secretsmanager:GetSecretValue`, `ssm:GetParameter`, `ssm:GetParameters` |

Both roles require MFA and trust a single identity account to assume them.

## Architecture

```
┌──────────────────────────┐
│  Identity Account        │
│  (283837321132)          │
│  IAM Users / SSO         │
└──────────┬───────────────┘
           │ sts:AssumeRole (MFA required)
           │
     ┌─────┼──────────────────────────────────┐
     │     │                                  │
     v     v                                  v
┌─────────────┐  ┌──────────────────┐  ┌──────────────────┐
│ Dev Account  │  │ Staging Account  │  │ Prod Account     │
│ 111111111111 │  │ 222222222222     │  │ 333333333333     │
│              │  │                  │  │                  │
│ AdminAccess  │  │ AdminAccess      │  │ AdminAccess      │
│ ReadAccess   │  │ ReadAccess       │  │ ReadAccess       │
└─────────────┘  └──────────────────┘  └──────────────────┘
```

## Repository Structure

```
.
├── modules/
│   └── cross-account-roles/       # Reusable Terraform module
│       ├── main.tf                 #   IAM roles, policies, attachments
│       ├── variables.tf            #   Input variables with validation
│       ├── outputs.tf              #   Output values
│       ├── versions.tf             #   Terraform/provider constraints
│       └── README.md               #   Module documentation
│
└── live/                           # Terragrunt live configurations
    ├── terragrunt.hcl              #   Root config (remote state, provider)
    ├── _envcommon/
    │   └── cross-account-roles.hcl #   Shared module inputs & source
    │
    ├── dev/
    │   ├── account.hcl             #   Dev account ID & region
    │   └── cross-account-roles/
    │       └── terragrunt.hcl      #   Includes root + envcommon
    │
    ├── staging/
    │   ├── account.hcl             #   Staging account ID & region
    │   └── cross-account-roles/
    │       └── terragrunt.hcl      #   Includes root + envcommon
    │
    └── production/
        ├── account.hcl             #   Production account ID & region
        └── cross-account-roles/
            └── terragrunt.hcl      #   Includes root + envcommon
```

### How the Config Hierarchy Works

```
live/terragrunt.hcl                  <-- Remote state (S3) + provider (assume role)
  │
  ├── live/{account}/account.hcl     <-- Account ID, name, region
  │
  └── live/_envcommon/               <-- Module source + shared default inputs
        cross-account-roles.hcl
              │
              └── live/{account}/cross-account-roles/terragrunt.hcl
                                     <-- Pulls in root + envcommon, adds overrides
```

Each account's `terragrunt.hcl` inherits from:
1. **Root** (`live/terragrunt.hcl`) -- remote state key is auto-namespaced per account, and the AWS provider assumes a role into the target account.
2. **Envcommon** (`live/_envcommon/cross-account-roles.hcl`) -- the module source path and default variable values (trusted account ID, MFA, tags, etc.).

Account-specific overrides (e.g., longer session duration for production) go in the account's own `terragrunt.hcl` `inputs` block.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) or [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.0
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) >= 0.50
- An S3 bucket and DynamoDB table for remote state (see [Setup](#remote-state-setup) below)
- AWS credentials with permission to assume `OrganizationAccountAccessRole` (or your equivalent) in each target account

## Setup

### 1. Update Placeholder Values

There are several `TODO` placeholders you must update before deploying:

| File | Value to Update |
|---|---|
| `live/terragrunt.hcl` | `state_bucket`, `state_lock_table`, `state_region` |
| `live/_envcommon/cross-account-roles.hcl` | `trusted_account_id` (your identity account) |
| `live/dev/account.hcl` | `account_id` |
| `live/staging/account.hcl` | `account_id` |
| `live/production/account.hcl` | `account_id` |

### 2. Remote State Setup

Create the S3 bucket and DynamoDB lock table (one-time, typically in the management account):

```bash
# Create state bucket
aws s3api create-bucket \
  --bucket my-org-terraform-state \
  --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket my-org-terraform-state \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket my-org-terraform-state \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'

# Block public access
aws s3api put-public-access-block \
  --bucket my-org-terraform-state \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Create lock table
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 3. Assume-Role Permissions

Terragrunt assumes `OrganizationAccountAccessRole` in each target account. This role is created automatically by AWS Organizations when you create member accounts. If you use a different role, update the `role_arn` in `live/terragrunt.hcl`.

Your local AWS credentials (or CI/CD role) must have permission to call `sts:AssumeRole` on the deployment role in each target account.

## Deploying

### Single Account

```bash
cd live/dev/cross-account-roles
terragrunt plan
terragrunt apply
```

### All Accounts at Once

```bash
cd live
terragrunt run-all plan
terragrunt run-all apply
```

### Specific Accounts

```bash
cd live
terragrunt run-all plan \
  --terragrunt-include-dir "dev/*" \
  --terragrunt-include-dir "staging/*"
```

### Destroying

```bash
# Single account
cd live/dev/cross-account-roles
terragrunt destroy

# All accounts
cd live
terragrunt run-all destroy
```

## Adding a New Account

1. Create the account directory:

   ```bash
   mkdir -p live/new-account/cross-account-roles
   ```

2. Create `live/new-account/account.hcl`:

   ```hcl
   locals {
     account_name = "new-account"
     account_id   = "444444444444"
     aws_region   = "us-east-1"
   }
   ```

3. Create `live/new-account/cross-account-roles/terragrunt.hcl`:

   ```hcl
   include "root" {
     path = find_in_parent_folders()
   }

   include "envcommon" {
     path   = "${dirname(find_in_parent_folders())}/_envcommon/cross-account-roles.hcl"
     expose = true
   }
   ```

4. Deploy:

   ```bash
   cd live/new-account/cross-account-roles
   terragrunt apply
   ```

## Adding a New Module

To deploy additional resources (e.g., a VPC baseline) across all accounts:

1. Create the module in `modules/new-module/`.
2. Create `live/_envcommon/new-module.hcl` with the shared config.
3. Add `live/{account}/new-module/terragrunt.hcl` for each account.

## Per-Account Overrides

Each account can override any input from the envcommon config. For example, to increase the session duration for production:

```hcl
# live/production/cross-account-roles/terragrunt.hcl

include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/cross-account-roles.hcl"
  expose = true
}

inputs = {
  max_session_duration = 7200
}
```

## State File Layout

State files are automatically namespaced per account and module:

```
s3://my-org-terraform-state/
  ├── dev/cross-account-roles/terraform.tfstate
  ├── staging/cross-account-roles/terraform.tfstate
  └── production/cross-account-roles/terraform.tfstate
```

## Security Considerations

- The identity account ID (`trusted_account_id`) is the single source of trust. Guard it carefully.
- MFA is enforced by default on both roles.
- The read-only role explicitly denies access to secrets and SSM parameters.
- The admin role grants full `AdministratorAccess` -- audit usage via CloudTrail.
- Remote state is encrypted at rest (S3 SSE) and locked via DynamoDB to prevent concurrent modifications.
- The `OrganizationAccountAccessRole` used by Terragrunt should be scoped down from `AdministratorAccess` in production environments.
