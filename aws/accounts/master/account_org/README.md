# AWS Organization Infrastructure - Terraform / Terragrunt

Terraform modules and Terragrunt configuration for managing AWS Organization-wide infrastructure. Ported from CloudFormation StackSet templates to Terraform modules deployable across multiple AWS accounts and regions via Terragrunt.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Directory Structure](#directory-structure)
- [Modules](#modules)
  - [audit-resources](#audit-resources)
  - [common-resources](#common-resources)
  - [security-alarms](#security-alarms)
  - [cross-account-roles](#cross-account-roles)
  - [master-account-roles](#master-account-roles)
  - [config-recorder](#config-recorder)
  - [config-rules](#config-rules)
  - [required-tags](#required-tags)
  - [conformance-packs](#conformance-packs)
- [Deployment Order](#deployment-order)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Deploy a Single Module](#deploy-a-single-module)
  - [Deploy All Modules in an Account](#deploy-all-modules-in-an-account)
  - [Deploy Everything](#deploy-everything)
- [Adding a New Account](#adding-a-new-account)
- [Adding a New Region](#adding-a-new-region)
- [CloudFormation to Terraform Mapping](#cloudformation-to-terraform-mapping)
- [Sensitive Values](#sensitive-values)

---

## Overview

This repository manages the foundational AWS infrastructure deployed across an AWS Organization, including:

- **Centralized audit logging** - CloudTrail and Config data stored in a dedicated audit account with KMS encryption
- **Security monitoring** - CIS Benchmark CloudWatch alarms (CIS 1.1, 3.1-3.14) deployed to every account
- **Cross-account access** - IAM roles with MFA requirements for admin and read-only access
- **Compliance** - AWS Config rules, conformance packs (IAM, S3, PCI), and tag enforcement
- **Per-account resources** - Deployment S3 buckets, SNS notification topics

## Architecture

```
                    ┌─────────────────────────────┐
                    │       Audit Account          │
                    │                              │
                    │  audit-resources module:      │
                    │  - CloudTrail S3 + KMS       │
                    │  - Config S3 + KMS           │
                    │  - Conformance Pack S3       │
                    │  - config-recorder           │
                    └──────────┬──────────────────┘
                               │
          ┌────────────────────┼─────────────────────┐
          │                    │                     │
          ▼                    ▼                     ▼
┌──────────────────┐ ┌────────────────┐  ┌───────────────────┐
│ Management Acct  │ │ Production     │  │ Development       │
│                  │ │                │  │                   │
│ master-account-  │ │ Sub-accounts   │  │ Sub-accounts      │
│   roles (only)   │ │ get:           │  │ get:              │
│                  │ │                │  │                   │
│                  │ │ - common-      │  │ - common-         │
│                  │ │   resources    │  │   resources       │
│                  │ │ - security-    │  │ - security-       │
│                  │ │   alarms      │  │   alarms          │
│                  │ │ - cross-acct-  │  │ - cross-acct-     │
│                  │ │   roles        │  │   roles           │
│                  │ │ - config-      │  │ - config-         │
│                  │ │   recorder     │  │   recorder        │
│                  │ │ - config-rules │  │ - config-rules    │
└──────────────────┘ └────────────────┘  └───────────────────┘
```

## Directory Structure

```
master/
├── scripts/
│   └── generate_account_dirs.sh      # Auto-generate sub-account directories from AWS OUs
│
├── modules/                          # Reusable Terraform modules
│   ├── audit-resources/              # Central audit S3 buckets + KMS keys
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── common-resources/             # Per-account deployment bucket + SNS
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── security-alarms/              # CloudTrail + CIS CloudWatch alarms
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── cross-account-roles/          # Admin + read-only IAM roles
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── master-account-roles/         # Backup + Route53 IAM roles
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── config-recorder/              # AWS Config recorder + delivery
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── config-rules/                 # Config rules + SSM remediation
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── required-tags/                # Required tags Config rule
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   └── conformance-packs/            # IAM, S3, PCI, Other packs
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── templates/
│           ├── iam.yaml
│           ├── s3.yaml
│           ├── pci.yaml
│           └── other.yaml
│
└── live/                             # Terragrunt deployment configurations
    ├── terragrunt.hcl                # Root config (provider, backend, tags)
    ├── env.hcl                       # Target OUs and regions for generate_account_dirs.sh
    ├── _envcommon/
    │   └── common_vars.hcl           # Shared variables (account IDs, org ID, etc.)
    │
    ├── audit/                        # Audit account deployments
    │   ├── account.hcl
    │   └── eu-west-1/
    │       ├── region.hcl
    │       ├── audit-resources/
    │       │   └── terragrunt.hcl
    │       └── config-recorder/
    │           └── terragrunt.hcl
    │
    ├── management/                   # Management account (master-account-roles only)
    │   ├── account.hcl
    │   └── eu-west-1/
    │       ├── region.hcl
    │       └── master-account-roles/
    │
    ├── production/                   # Production account deployments
    │   ├── account.hcl
    │   ├── eu-west-1/
    │   │   ├── region.hcl
    │   │   ├── common-resources/
    │   │   ├── security-alarms/
    │   │   ├── cross-account-roles/
    │   │   ├── config-recorder/
    │   │   └── config-rules/
    │   └── af-south-1/
    │       ├── region.hcl
    │       ├── common-resources/
    │       └── config-recorder/
    │
    └── development/                  # Development account deployments
        ├── account.hcl
        ├── eu-west-1/
        │   ├── region.hcl
        │   ├── common-resources/
        │   ├── security-alarms/
        │   ├── cross-account-roles/
        │   ├── config-recorder/
        │   └── config-rules/
        └── af-south-1/
            ├── region.hcl
            ├── common-resources/
            └── config-recorder/
```

---

## Modules

### audit-resources

Central audit account resources for organization-wide logging.

| Resource | Type | Description |
|----------|------|-------------|
| CloudTrail KMS Key | `aws_kms_key` | CMK for encrypting CloudTrail S3 bucket with org-wide decrypt access |
| CloudTrail S3 Bucket | `aws_s3_bucket` | Central bucket for organization CloudTrail logs |
| Config KMS Key | `aws_kms_key` | CMK for encrypting Config S3 bucket |
| Config S3 Bucket | `aws_s3_bucket` | Central bucket for Config delivery data |
| Conformance S3 Bucket | `aws_s3_bucket` | Bucket for Config Conformance Pack delivery |

**Key Variables:**

| Variable | Description |
|----------|-------------|
| `organization_id` | AWS Organization ID |
| `cloudtrail_bucket_name` | Name for CloudTrail bucket |
| `config_bucket_name` | Name for Config bucket |
| `conformance_bucket_name` | Name for Conformance Pack bucket |
| `cloudtrail_write_account_id` | Account ID allowed to write CloudTrail logs |
| `devops_account_id` | Account ID with read access to CloudTrail bucket |

---

### common-resources

Per-account resources deployed to every member account.

| Resource | Type | Description |
|----------|------|-------------|
| Deployment Bucket | `aws_s3_bucket` | `deployment-{account_id}-{region}` for Lambda/serverless packages. KMS encrypted, versioned, 30-day lifecycle. |
| Critical SNS Topic | `aws_sns_topic` | `devops-events-critical` with email subscription |
| General SNS Topic | `aws_sns_topic` | `devops-events-general` with email subscription |

**Key Variables:**

| Variable | Description |
|----------|-------------|
| `critical_notifications_email` | Email for critical alerts |
| `general_notifications_email` | Email for general alerts |

---

### security-alarms

CIS Benchmark CloudWatch alarms with per-account CloudTrail.

Creates a dedicated CloudTrail trail with CloudWatch Logs integration, plus metric filters and alarms for all CIS 3.x controls:

| CIS Control | Alarm | Always/Conditional |
|-------------|-------|--------------------|
| CIS 3.1 | Unauthorized API calls | Always |
| CIS 3.2 | Console sign-in without MFA (SSO excluded) | `external_idp = true` |
| CIS 1.1/3.3 | Root account activity | Always |
| CIS 3.4 | IAM policy changes | `security_hub_rules = true` |
| CIS 3.5 | CloudTrail config changes | `security_hub_rules = true` |
| CIS 3.6 | Console login failures | Always |
| CIS 3.7 | CMK disable/deletion | `security_hub_rules = true` |
| CIS 3.8 | S3 bucket policy changes | `security_hub_rules = true` |
| CIS 3.9 | AWS Config changes | `security_hub_rules = true` |
| CIS 3.10 | Security group changes | `security_hub_rules = true` |
| CIS 3.11 | NACL changes | `security_hub_rules = true` |
| CIS 3.12 | Network gateway changes | `security_hub_rules = true` |
| CIS 3.13 | Route table changes | `security_hub_rules = true` |
| CIS 3.14 | VPC changes | `security_hub_rules = true` |

**Key Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `security_hub_rules` | `true` | Enable CIS 3.4-3.14 alarms |
| `external_idp` | `false` | Enable SSO-aware MFA alarm (CIS 3.2) |
| `sns_lambda_arn` | `""` | Optional Lambda ARN for SNS subscription |

---

### cross-account-roles

IAM roles for cross-account access with MFA requirement.

| Role | Managed Policy | Extra |
|------|---------------|-------|
| `CrossAccountAdminAccess` | `AdministratorAccess` | MFA required |
| `CrossAccountReadAccess` | `ReadOnlyAccess` | MFA required, explicit deny on `secretsmanager:GetSecretValue`, `ssm:GetParameter(s)` |

**Key Variables:**

| Variable | Description |
|----------|-------------|
| `identity_account_id` | Account ID trusted to assume these roles |

---

### master-account-roles

IAM roles deployed only in the management/master account.

| Role | Description |
|------|-------------|
| `ORGRoleForBackupServices` | Assumed by backup account for Route53 read + EC2 backup operations |
| `Route53AccessRole` | Assumed by specified accounts for Route53 record management |

**Key Variables:**

| Variable | Description |
|----------|-------------|
| `backup_services_account_id` | Account ID for backup services |
| `route53_trusted_account_ids` | List of account IDs trusted for Route53 access |
| `hosted_zone_ids` | List of Route53 hosted zone IDs the role can manage |

---

### config-recorder

AWS Config Configuration Recorder and Delivery Channel.

| Resource | Description |
|----------|-------------|
| `aws_config_configuration_recorder` | Records all resource types including global resources |
| `aws_config_delivery_channel` | Delivers to central Config S3 bucket with KMS encryption, 24h snapshot |

**Key Variables:**

| Variable | Description |
|----------|-------------|
| `config_s3_bucket_name` | Central Config S3 bucket name |
| `config_kms_key_arn` | KMS key ARN for delivery encryption |

---

### config-rules

AWS Config rules with automated SSM remediation.

| Resource | Description |
|----------|-------------|
| SSM Automation Document | Publishes SNS notification on non-compliance |
| IAM Role (primary region only) | `CustomConfigRulesAutomation` for SSM to publish to SNS |
| Config Rule: `S3MandatoryTags` | Checks S3 buckets for mandatory `description` tag |
| Remediation Configuration | Auto-triggers SNS notification when S3 buckets are non-compliant |

The automation IAM role is only created in the primary region (`eu-west-1` by default). Remediation is excluded from specified regions (e.g. `af-south-1`).

**Key Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `primary_region` | `eu-west-1` | Region where automation role is created |
| `excluded_regions` | `["af-south-1"]` | Regions where remediation is skipped |
| `mandatory_tag_key` | `description` | Tag key to enforce on S3 buckets |

---

### required-tags

Standalone Config rule for enforcing up to 6 required tags across 30 resource types.

Supports: ACM, AutoScaling, CloudFormation, CodeBuild, DynamoDB, EC2 (8 types), ELB/ALB, RDS (5 types), Redshift (5 types), S3.

**Key Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `tag1_key` | `CostCenter` | First required tag key |
| `tag1_value` - `tag6_value` | `""` | Optional tag values (up to 6 key/value pairs) |

---

### conformance-packs

AWS Config Conformance Packs using CloudFormation-native YAML templates.

| Pack | Rules | Description |
|------|-------|-------------|
| **IAM** | 11 rules | Access key rotation, password policy, MFA, unused credentials, admin access |
| **S3** | 3 rules | Public read/write prohibited, server-side encryption |
| **PCI** | 22 rules | PCI DSS controls: public access checks, VPC, MFA, SSH, security groups |
| **Other** | 2 rules | S3 replication, SSL-only requests |

Each pack can be individually enabled/disabled.

---

## Deployment Order

Modules have dependencies that must be respected:

```
1. audit-resources          (creates central S3 buckets and KMS keys)
   │
   ├── 2. config-recorder   (depends on Config S3 bucket + KMS key)
   │
   ├── 3. common-resources  (creates SNS topics needed by config-rules)
   │   │
   │   └── 4. config-rules  (depends on devops-events-general SNS topic)
   │
   ├── 5. conformance-packs (depends on config-recorder being active)
   │
   ├── 6. security-alarms   (self-contained per account)
   │
   ├── 7. cross-account-roles (independent)
   │
   ├── 8. master-account-roles (management account only)
   │
   └── 9. required-tags     (independent)
```

When using Terragrunt, you can add `dependencies` blocks to enforce this ordering automatically.

---

## Prerequisites

- **Terraform** >= 1.3.0
- **Terragrunt** >= 0.45.0
- **AWS CLI** configured with credentials for each target account
- AWS Organizations enabled with organizational units configured
- The AWS Config service-linked role must exist in each account (`AWSServiceRoleForConfig`)

---

## Configuration

### 1. Update common variables

Edit `live/_envcommon/common_vars.hcl` with your actual values:

```hcl
locals {
  organization_id             = "o-your-org-id"
  audit_account_id            = "111111111111"
  identity_account_id         = "222222222222"
  devops_account_id           = "333333333333"
  cloudtrail_write_account_id = "444444444444"
  backup_services_account_id  = "555555555555"
  route53_trusted_account_ids = ["666666666666", "777777777777"]
  hosted_zone_ids             = ["Z0000000000001", "Z0000000000002"]
  # ... etc
}
```

### 2. Update account configurations

Edit each `account.hcl` file with the real account ID:

```hcl
# live/production/account.hcl
locals {
  account_name = "production"
  account_id   = "123456789012"   # Your actual account ID
}
```

### 3. Configure remote state

The root `terragrunt.hcl` uses S3 backend with DynamoDB locking. Ensure the state bucket and DynamoDB table exist in each account/region, or use Terragrunt's `remote_state` auto-creation.

### 4. Configure authentication

Uncomment and configure the `assume_role` block in `live/terragrunt.hcl` if deploying from a central account:

```hcl
provider "aws" {
  region = "..."
  assume_role {
    role_arn = "arn:aws:iam::${local.account_id}:role/TerraformExecutionRole"
  }
}
```

---

## Usage

### Deploy a Single Module

```bash
cd live/production/eu-west-1/common-resources
terragrunt apply
```

### Deploy All Modules in an Account

```bash
cd live/production
terragrunt run-all apply
```

### Deploy All Modules in a Region

```bash
cd live/production/eu-west-1
terragrunt run-all apply
```

### Deploy Everything

```bash
cd live
terragrunt run-all apply
```

### Plan Changes

```bash
cd live/production/eu-west-1/security-alarms
terragrunt plan
```

### Destroy

```bash
cd live/development/eu-west-1/common-resources
terragrunt destroy
```

---

## Adding a New Account

The recommended approach is to use the `generate_account_dirs.sh` script, which queries AWS Organizations to discover accounts in the target OUs and auto-generates the correct directory structure.

### Automated (recommended)

1. Configure target OUs and regions in `live/env.hcl`:

```hcl
locals {
  target_ou_ids = [
    "ou-xxxx-cccccccc", # Production OU
    "ou-xxxx-dddddddd", # Development OU
  ]

  target_regions = [
    "eu-west-1",  # Primary region (all modules)
    "af-south-1", # Secondary region (common-resources + config-recorder only)
  ]
}
```

2. Run the script (requires AWS CLI credentials with `organizations:ListAccountsForParent` permission):

```bash
# Preview what will be created
./scripts/generate_account_dirs.sh --dry-run

# Create the directories
./scripts/generate_account_dirs.sh
```

The script will:
- Query each OU for active accounts
- Skip the audit and management accounts (identified from `common_vars.hcl`)
- Create `account.hcl`, `region.hcl`, and module `terragrunt.hcl` files for each account/region
- Primary region gets all sub-account modules: `common-resources`, `config-recorder`, `config-rules`, `cross-account-roles`, `security-alarms`
- Secondary regions get only: `common-resources`, `config-recorder`
- Existing directories are never overwritten

### Manual

1. Create a new directory under `live/`:

```bash
mkdir -p live/new-account/eu-west-1
```

2. Create `account.hcl`:

```hcl
locals {
  account_name = "new-account"
  account_id   = "999999999999"
}
```

3. Create `region.hcl` in each region directory:

```hcl
locals {
  aws_region = "eu-west-1"
}
```

4. Add module directories with `terragrunt.hcl` files. Copy from an existing account (e.g. `production/`) and adjust as needed.

---

## Adding a New Region

1. Create a new region directory under the account:

```bash
mkdir -p live/production/us-east-1/{common-resources,config-recorder}
```

2. Create `region.hcl`:

```hcl
locals {
  aws_region = "us-east-1"
}
```

3. Copy the relevant module `terragrunt.hcl` files from an existing region and adjust inputs if needed.

---

## CloudFormation to Terraform Mapping

| Original CloudFormation | Terraform Module | Deployment Model |
|------------------------|------------------|------------------|
| `stacksets/security-alarms.yml` | `modules/security-alarms` | Per-account via Terragrunt |
| `stacksets/cross-account-roles.yml` | `modules/cross-account-roles` | Per-account via Terragrunt |
| `stacksets/common-resources.yml` | `modules/common-resources` | Per-account/region via Terragrunt |
| `stacksets/config-recorder.yml` | `modules/config-recorder` | Per-account/region via Terragrunt |
| `stacksets/config-rules.yml` | `modules/config-rules` | Per-account/region via Terragrunt |
| `stacksets/master-account-roles.yml` | `modules/master-account-roles` | Management account only |
| `audit-account/organisation-audit-resources.json` | `modules/audit-resources` | Audit account only |
| `REQUIRED_TAGS.template` | `modules/required-tags` | Per-account via Terragrunt |
| `conformance-packs/*.yml` | `modules/conformance-packs` | Per-account/region via Terragrunt |

---

## Sensitive Values

All AWS account IDs, organization IDs, OU IDs, hosted zone IDs, and KMS key ARNs have been replaced with dummy values. Update these in `live/_envcommon/common_vars.hcl` before deploying:

| Placeholder | Description | Where to Update |
|-------------|-------------|-----------------|
| `o-abc123def4` | AWS Organization ID | `common_vars.hcl` |
| `111111111111` - `777777777777` | AWS Account IDs | `common_vars.hcl`, `account.hcl` files |
| `Z0000000000001`, `Z0000000000002` | Route53 Hosted Zone IDs | `common_vars.hcl` |
| `ou-xxxx-aaaaaaaa` etc. | Organizational Unit IDs | `common_vars.hcl` |
| `r-xxxx` | Organization Root ID | `common_vars.hcl` |
| `arn:aws:kms:...xxx...` | KMS Key ARN | `common_vars.hcl` |
| `ops-critical@example.com` | Notification emails | `common_vars.hcl` |
| `ops-general@example.com` | Notification emails | `common_vars.hcl` |
