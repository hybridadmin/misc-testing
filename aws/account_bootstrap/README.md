# AWS Account Bootstrap -- Multi-Account Deployment

Terraform modules + Terragrunt live configurations for bootstrapping foundational resources across an AWS Organization. Each module is converted from an existing CloudFormation StackSet or template.

## Modules

| Module | Description | Deployed To |
|---|---|---|
| [`cross-account-roles`](modules/cross-account-roles/) | IAM roles allowing a trusted identity account to assume admin/read-only access | dev, staging, production |
| [`kms-keys`](modules/kms-keys/) | KMS key for encrypting shared AMIs across the organisation | dev, staging, production |
| [`backup-vault`](modules/backup-vault/) | DR backup vault, S3 bucket, KMS key, and cross-account IAM role | backup |

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
│ KMS Key      │  │ KMS Key          │  │ KMS Key          │
└─────────────┘  └──────────────────┘  └──────────────────┘

┌──────────────────────────┐
│  Source Account(s)       │
│  (520453265019)          │
│  sts:AssumeRole ─────────┼──┐
└──────────────────────────┘  │
                              v
                   ┌──────────────────────┐
                   │  Backup Account       │
                   │  444444444444         │
                   │                       │
                   │  Backup Vault         │
                   │  KMS Key              │
                   │  S3 Bucket            │
                   │  Cross-Account Role   │
                   └──────────────────────┘
```

## Repository Structure

```
.
├── modules/
│   ├── cross-account-roles/       # IAM cross-account roles
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── versions.tf
│   │   └── README.md
│   │
│   ├── kms-keys/                  # Organisation-wide AMI encryption key
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── versions.tf
│   │   └── README.md
│   │
│   └── backup-vault/              # DR backup vault infrastructure
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── README.md
│
└── live/                           # Terragrunt live configurations
    ├── terragrunt.hcl              #   Root config (remote state, provider)
    ├── _envcommon/
    │   ├── cross-account-roles.hcl #   Shared config for cross-account-roles
    │   ├── kms-keys.hcl            #   Shared config for kms-keys
    │   └── backup-vault.hcl        #   Shared config for backup-vault
    │
    ├── dev/
    │   ├── account.hcl
    │   ├── cross-account-roles/
    │   │   └── terragrunt.hcl
    │   └── kms-keys/
    │       └── terragrunt.hcl
    │
    ├── staging/
    │   ├── account.hcl
    │   ├── cross-account-roles/
    │   │   └── terragrunt.hcl
    │   └── kms-keys/
    │       └── terragrunt.hcl
    │
    ├── production/
    │   ├── account.hcl
    │   ├── cross-account-roles/
    │   │   └── terragrunt.hcl
    │   └── kms-keys/
    │       └── terragrunt.hcl
    │
    └── backup/
        ├── account.hcl
        └── backup-vault/
            └── terragrunt.hcl
```

### How the Config Hierarchy Works

```
live/terragrunt.hcl                  <-- Remote state (S3) + provider (assume role)
  │
  ├── live/{account}/account.hcl     <-- Account ID, name, region
  │
  └── live/_envcommon/               <-- Module source + shared default inputs
        {module-name}.hcl
              │
              └── live/{account}/{module-name}/terragrunt.hcl
                                     <-- Pulls in root + envcommon, adds overrides
```

Each account's `terragrunt.hcl` inherits from:
1. **Root** (`live/terragrunt.hcl`) -- remote state key is auto-namespaced per account, and the AWS provider assumes a role into the target account.
2. **Envcommon** (`live/_envcommon/{module-name}.hcl`) -- the module source path and default variable values.

Account-specific overrides go in the account's own `terragrunt.hcl` `inputs` block.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) or [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.0
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) >= 0.50
- An S3 bucket and DynamoDB table for remote state (see [Setup](#remote-state-setup) below)
- AWS credentials with permission to assume `OrganizationAccountAccessRole` (or your equivalent) in each target account

## Setup

### 1. Update Placeholder Values

There are several placeholder values you must update before deploying:

| File | Value to Update |
|---|---|
| `live/terragrunt.hcl` | `state_bucket`, `state_lock_table`, `state_region` |
| `live/_envcommon/cross-account-roles.hcl` | `trusted_account_id` |
| `live/_envcommon/kms-keys.hcl` | `organization_id` |
| `live/_envcommon/backup-vault.hcl` | `organization_id`, `backup_source_account_ids`, `sns_topic_arn`, `cross_account_role_name`, `bucket_read_org_paths` |
| `live/dev/account.hcl` | `account_id` |
| `live/staging/account.hcl` | `account_id` |
| `live/production/account.hcl` | `account_id` |
| `live/backup/account.hcl` | `account_id` |

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

### Single Module in a Single Account

```bash
cd live/dev/kms-keys
terragrunt plan
terragrunt apply
```

### All Modules in a Single Account

```bash
cd live/dev
terragrunt run-all plan
terragrunt run-all apply
```

### A Specific Module Across All Accounts

```bash
cd live
terragrunt run-all plan --terragrunt-include-dir "*/kms-keys"
terragrunt run-all apply --terragrunt-include-dir "*/kms-keys"
```

### All Modules in All Accounts

```bash
cd live
terragrunt run-all plan
terragrunt run-all apply
```

### Specific Accounts Only

```bash
cd live
terragrunt run-all plan \
  --terragrunt-include-dir "dev/*" \
  --terragrunt-include-dir "staging/*"
```

### Backup Account Only

```bash
cd live/backup/backup-vault
terragrunt plan
terragrunt apply
```

### Destroying

```bash
# Single module in one account
cd live/dev/kms-keys
terragrunt destroy

# All modules in all accounts
cd live
terragrunt run-all destroy
```

> **Note:** The `backup-vault` module has `prevent_destroy = true` on its KMS key, backup vault, and S3 bucket. You must remove the lifecycle blocks from the module code before `terragrunt destroy` will succeed.

## Adding a New Account

1. Create the account directory and config:

   ```bash
   mkdir -p live/new-account
   ```

2. Create `live/new-account/account.hcl`:

   ```hcl
   locals {
     account_name = "new-account"
     account_id   = "555555555555"
     aws_region   = "us-east-1"
   }
   ```

3. Add module directories for each module to deploy:

   ```bash
   mkdir -p live/new-account/cross-account-roles
   mkdir -p live/new-account/kms-keys
   ```

4. Create `terragrunt.hcl` in each module directory:

   ```hcl
   include "root" {
     path = find_in_parent_folders()
   }

   include "envcommon" {
     path   = "${dirname(find_in_parent_folders())}/_envcommon/cross-account-roles.hcl"
     expose = true
   }
   ```

5. Deploy:

   ```bash
   cd live/new-account
   terragrunt run-all apply
   ```

## Adding a New Module

1. Create the module in `modules/new-module/` with the standard files (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).

2. Create `live/_envcommon/new-module.hcl` with the shared config:

   ```hcl
   locals {
     account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
     account_name = local.account_vars.locals.account_name
     account_id   = local.account_vars.locals.account_id
   }

   terraform {
     source = "${get_repo_root()}/modules/new-module"
   }

   inputs = {
     # Default input values here
     tags = {
       AccountName = local.account_name
       AccountId   = local.account_id
       Module      = "new-module"
     }
   }
   ```

3. Add `live/{account}/new-module/terragrunt.hcl` for each account that should receive the module:

   ```hcl
   include "root" {
     path = find_in_parent_folders()
   }

   include "envcommon" {
     path   = "${dirname(find_in_parent_folders())}/_envcommon/new-module.hcl"
     expose = true
   }
   ```

## Per-Account Overrides

Each account can override any input from the envcommon config. For example, to use a different KMS key alias in production:

```hcl
# live/production/kms-keys/terragrunt.hcl

include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/kms-keys.hcl"
  expose = true
}

inputs = {
  alias_name = "production-ami-encryption"
}
```

## State File Layout

State files are automatically namespaced per account and module:

```
s3://my-org-terraform-state/
  ├── dev/
  │   ├── cross-account-roles/terraform.tfstate
  │   └── kms-keys/terraform.tfstate
  ├── staging/
  │   ├── cross-account-roles/terraform.tfstate
  │   └── kms-keys/terraform.tfstate
  ├── production/
  │   ├── cross-account-roles/terraform.tfstate
  │   └── kms-keys/terraform.tfstate
  └── backup/
      └── backup-vault/terraform.tfstate
```

## Security Considerations

- **Identity account trust** -- the `trusted_account_id` in `cross-account-roles` is the single source of trust for cross-account access. Guard it carefully.
- **MFA enforcement** -- cross-account roles require MFA by default.
- **Read-only role restrictions** -- the read-only role explicitly denies access to secrets and SSM parameters.
- **Organisation-scoped KMS** -- KMS key policies use `aws:PrincipalOrgID` to restrict access, so no individual account IDs need to be maintained as accounts are added or removed.
- **Backup vault protection** -- the backup vault, KMS key, and S3 bucket have `prevent_destroy` lifecycle rules to prevent accidental deletion.
- **Least-privilege backup role** -- the cross-account backup role uses separate policies scoped to the minimum required actions.
- **Encrypted state** -- remote state is encrypted at rest (S3 SSE) and locked via DynamoDB to prevent concurrent modifications.
- **Key rotation** -- all KMS keys have automatic annual rotation enabled by default.
