# DevOps Bootstrap (01_bootstrap)

Terraform modules and Terragrunt configurations for bootstrapping the DevOps
AWS account with the foundational infrastructure required for CI/CD operations.
Ported from CloudFormation StackSet templates to native Terraform with
Terragrunt.

## Architecture Overview

This project deploys four infrastructure modules into the DevOps account:

| Module | Purpose | Source CF Template |
|---|---|---|
| **kms-keys** | KMS keys for encrypting AMIs shared across the organization | `kms-keys.yml` |
| **cross-account-roles** | IAM roles/policies for cross-account CI/CD deployments | `devops-cross-account-roles.yml` |
| **build-vpc** | Minimal VPC for Packer AMI builds (public subnet + S3 endpoint) | `devops-build-vpc.yml` |
| **cdk-bootstrap** | CDK bootstrap resources (S3, ECR, IAM roles, SSM parameter) | Best practices (v21) |

### Deployment Topology

```
DevOps Account (000000000000)
├── kms-keys          ─ AMI encryption key
├── cross-account-roles ─ DevOps deployment role + StackSet roles + CFN policy
├── build-vpc         ─ VPC for AMI factory builds
└── cdk-bootstrap     ─ CDK S3/ECR/IAM infrastructure
```

## Directory Structure

```
01_bootstrap/
├── terragrunt.hcl                          # Root config: remote state + provider
├── .gitignore
│
├── _envcommon/                             # Shared default inputs per module
│   ├── kms-keys.hcl
│   ├── cross-account-roles.hcl
│   ├── build-vpc.hcl
│   └── cdk-bootstrap.hcl
│
├── envs/                                   # Account deployment
│   └── devops/
│       ├── account.hcl                     # Account identity (name, ID, region)
│       ├── kms-keys/terragrunt.hcl
│       ├── cross-account-roles/terragrunt.hcl
│       ├── build-vpc/terragrunt.hcl
│       └── cdk-bootstrap/terragrunt.hcl
│
├── modules/                                # Terraform modules
│   ├── kms-keys/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── cross-account-roles/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── build-vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   └── cdk-bootstrap/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
│
└── scripts/
    └── generate_account_dirs.sh            # Account scaffolding tool
```

## Configuration Hierarchy

The four-layer config hierarchy eliminates duplication:

```
Layer 1: terragrunt.hcl (root)
         → Remote state (S3 + DynamoDB) + AWS provider

Layer 2: _envcommon/{module}.hcl
         → Module source path + shared default inputs

Layer 3: envs/devops/account.hcl
         → Account identity: account_name, account_id, aws_region

Layer 4: envs/devops/{module}/terragrunt.hcl
         → Includes layers 1+2, optional per-module input overrides
```

## Prerequisites

- **Terraform** >= 1.0
- **Terragrunt** >= 0.45
- **AWS CLI** configured with credentials for the DevOps account
- **S3 bucket** for Terraform state (`myorg-terraform-state` by default)
- **DynamoDB table** for state locking (`terraform-locks` by default)

## Setup

### 1. Configure Remote State

Edit `terragrunt.hcl` (root) to set your state backend:

```hcl
locals {
  state_bucket     = "your-terraform-state-bucket"
  state_lock_table = "your-terraform-locks-table"
  state_region     = "eu-west-1"
}
```

### 2. Set Account ID

Update `envs/devops/account.hcl` with the real DevOps account ID:

```hcl
locals {
  account_name = "devops"
  account_id   = "123456789012"  # Your actual DevOps account ID
  aws_region   = "eu-west-1"
}
```

### 3. Configure Shared Defaults

Review and update `_envcommon/*.hcl` files. Key values to configure:

| File | Key Variable | Description |
|---|---|---|
| `kms-keys.hcl` | `organization_id` | Your AWS Organization ID |
| `cross-account-roles.hcl` | `devops_account_id` | The DevOps/CI-CD account ID |
| `cross-account-roles.hcl` | `devops_kms_key_arns` | KMS key ARNs from the DevOps account |
| `cdk-bootstrap.hcl` | `trusted_accounts` | Account IDs trusted for CDK deployments |
| `cdk-bootstrap.hcl` | `cloudformation_execution_policies` | Execution policy ARNs |
| `build-vpc.hcl` | `software_bucket_name` | S3 bucket with AMI build software |

## Deploying

### Deploy All Modules

```bash
cd envs/devops
terragrunt run-all plan    # Review changes
terragrunt run-all apply   # Apply changes
```

### Deploy a Single Module

```bash
cd envs/devops/kms-keys
terragrunt plan
terragrunt apply
```

### Recommended Deployment Order

Modules should be deployed in this order due to dependencies:

1. **kms-keys** -- No dependencies
2. **cross-account-roles** -- No strict dependencies (references KMS key ARNs by value)
3. **build-vpc** -- No strict dependencies
4. **cdk-bootstrap** -- Depends on `cross-account-roles` (references the CFN execution policy)

When using `terragrunt run-all`, Terragrunt handles ordering automatically if
you add `dependency` blocks (not included by default to keep configs minimal).

### Destroying

```bash
cd envs/devops/kms-keys
terragrunt destroy

# Or destroy everything:
cd envs/devops
terragrunt run-all destroy
```

**Warning:** The `cdk-bootstrap` module has `prevent_destroy = true` on the S3
staging bucket. Remove this lifecycle rule before destroying if intended.

## Module Details

### kms-keys

Creates a KMS key and alias for encrypting AMIs shared across the AWS
Organization.

**Key features:**
- Organization-scoped encrypt/decrypt access via `aws:PrincipalOrgID`
- Organization-scoped grant management
- Admin role key management
- Automatic key rotation enabled by default

**Inputs:** `project`, `environment`, `organization_id`, `admin_role_name`,
`alias_name`, `deletion_window_in_days`, `enable_key_rotation`, `tags`

**Outputs:** `key_arn`, `key_id`, `alias_arn`, `alias_name`

### cross-account-roles

Creates IAM roles and policies for cross-account DevOps deployments. This is
the most comprehensive module, providing:

1. **CFN Execution Policy** (`ORGPolicyForCfnExecution`) -- Broad managed policy
   covering ~40+ AWS services for CloudFormation deployments
2. **StackSet Execution Role** -- Assumed by the account itself for StackSet ops
3. **StackSet Administration Role** -- Assumed by CloudFormation service
4. **DevOps Deployment Role** (`ORGRoleForDevopsDeployment`) -- Assumed by the
   DevOps account with two inline policies:
   - `build-copy-permissions`: ECR push/pull, EC2 image ops, Packer, KMS
   - `deployment-permissions`: S3 deployment buckets, SSM, CloudFormation, CDK
     roles, CloudFront, API Gateway, EKS, Lambda, ACM, ELB

**Inputs:** `devops_account_id`, `packer_account_ids`,
`deployment_role_name`, `cfn_execution_policy_name`, `devops_kms_key_arns`,
`deployment_bucket_regions`, `cdk_qualifier`, `configuration_bucket_name`,
`additional_cfn_via_services`, `tags`

**Outputs:** `cfn_execution_policy_arn`, `stackset_execution_role_arn`,
`stackset_admin_role_arn`, `devops_deployment_role_arn` (+ name variants)

### build-vpc

Creates a minimal VPC for building AMIs with Packer.

**Resources created:**
- VPC with configurable CIDR
- Internet Gateway + public route table
- One public subnet in the first AZ
- S3 Gateway VPC Endpoint
- EC2 Factory IAM role (SSM + S3 access) and instance profile

**Inputs:** `name_prefix`, `vpc_cidr`, `public_subnet_cidr`,
`enable_dns_support`, `enable_dns_hostnames`, `ssm_parameter_paths`,
`software_bucket_name`, `tags`

**Outputs:** `vpc_id`, `public_subnet_id`, `internet_gateway_id`,
`public_route_table_id`, `s3_endpoint_id`, `factory_role_arn`,
`factory_instance_profile_arn` (+ name/cidr variants)

### cdk-bootstrap

Modern Terraform implementation of CDK bootstrap (v21). Creates the
infrastructure required by AWS CDK for deploying applications.

**Resources created:**
- KMS key + alias for asset encryption (optional)
- S3 staging bucket (versioned, encrypted, public access blocked)
- S3 bucket policy (SSL-only)
- ECR repository for container assets (with lifecycle policy)
- IAM roles: file publishing, image publishing, lookup, deployment, CFN execution
- SSM parameter for bootstrap version tracking

**Key improvements over the original CloudFormation template:**
- Native Terraform lifecycle management
- ECR lifecycle policy to clean up untagged images
- KMS key rotation enabled by default
- Configurable bootstrap version (default v21, latest)
- Explicit resource dependencies and tagging

**Inputs:** `qualifier`, `trusted_accounts`, `trusted_accounts_for_lookup`,
`cloudformation_execution_policies`, `file_assets_bucket_name`,
`file_assets_bucket_kms_key_id`, `container_assets_repository_name`,
`enable_public_access_block`, `bootstrap_version`, `tags`

**Outputs:** `staging_bucket_name`, `staging_bucket_arn`, `ecr_repository_name`,
`ecr_repository_url`, `file_publishing_role_arn`, `image_publishing_role_arn`,
`lookup_role_arn`, `deploy_role_arn`, `cfn_exec_role_arn`, `assets_kms_key_arn`,
`bootstrap_version`

## Adding Additional Accounts

If you later need to deploy these modules to other accounts (e.g., dev,
staging, prod), you can use the scaffolding script or create directories
manually.

### Using the Scaffolding Script

```bash
./scripts/generate_account_dirs.sh
```

The script prompts for account name, 12-digit AWS account ID, region, and which
modules to include. It creates `account.hcl` and per-module `terragrunt.hcl`
files. Supports `--dry-run` mode.

Note: If deploying to other accounts, you may need to re-add an `assume_role`
block to the root `terragrunt.hcl` provider generation.

### Manually

1. Create `envs/{account-name}/account.hcl`:
   ```hcl
   locals {
     account_name = "new-account"
     account_id   = "123456789012"
     aws_region   = "eu-west-1"
   }
   ```

2. Create `envs/{account-name}/{module}/terragrunt.hcl` for each module:
   ```hcl
   include "root" {
     path = find_in_parent_folders()
   }
   include "envcommon" {
     path   = "${dirname(find_in_parent_folders())}/_envcommon/{module}.hcl"
     expose = true
   }
   ```

3. Add per-account overrides in the `inputs` block if needed.

## Per-Module Overrides

Override any default input at the leaf level:

```hcl
# envs/devops/kms-keys/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}
include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/kms-keys.hcl"
  expose = true
}

inputs = {
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
```

## State File Layout

State files are stored in S3 with automatic namespacing:

```
s3://myorg-terraform-state/
  devops-bootstrap/devops/kms-keys/terraform.tfstate
  devops-bootstrap/devops/cross-account-roles/terraform.tfstate
  devops-bootstrap/devops/build-vpc/terraform.tfstate
  devops-bootstrap/devops/cdk-bootstrap/terraform.tfstate
```

## CloudFormation to Terraform Mapping

| CloudFormation Source | Terraform Module | Key Differences |
|---|---|---|
| `kms-keys.yml` | `modules/kms-keys/` | Uses `aws_iam_policy_document` data source instead of inline JSON. Organization ID is variable instead of hardcoded. |
| `devops-cross-account-roles.yml` | `modules/cross-account-roles/` | IsIreland condition removed (Terraform handles per-region deployment natively via Terragrunt). Account IDs are variables. KMS key ARNs configurable. |
| `devops-build-vpc.yml` | `modules/build-vpc/` | Uses data source for AZ selection. Name prefix is configurable. SSM parameter paths and S3 bucket name are variables. |
| `bootstrap-template.yml` | `modules/cdk-bootstrap/` | Rewritten from scratch following CDK v21 best practices. Native Terraform resources instead of CF conditions/functions. ECR lifecycle policy added. |

## Security Considerations

- **No Assume Role:** The provider runs directly in the DevOps account using
  your current AWS credentials. No cross-account role assumption is needed.
- **Least Privilege:** The `cross-account-roles` module creates broad policies
  required for CI/CD. Review and restrict the `cfn_execution_policy` actions
  based on your actual service usage.
- **KMS Key Rotation:** Enabled by default on all KMS keys.
- **State Encryption:** S3 state backend is configured with encryption enabled.
- **CDK Execution Policy:** By default, the CDK bootstrap uses
  `ORGPolicyForCfnExecution` instead of `AdministratorAccess` for the CFN
  execution role, following the principle of least privilege.
- **Prevent Destroy:** The CDK staging bucket has `prevent_destroy = true` to
  prevent accidental data loss.

## Sensitive Values

All real account IDs, organization IDs, KMS key IDs, and hosted zone IDs have
been replaced with dummy values. Search for `TODO` comments to find values that
need to be replaced before deployment:

```bash
grep -r "TODO" envs/ _envcommon/
```

Dummy values used:
- Account IDs: `000000000000`
- Organization ID: `o-abc123def45`
- KMS Key ARNs: `arn:aws:kms:...:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee`
- S3 Buckets: `myorg-*` prefix
- SSM Parameters: `orgadmin` references
