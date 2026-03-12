# AWS Backups - Terraform/Terragrunt

Multi-account, multi-region AWS backup infrastructure deployed via Terraform modules and Terragrunt. Ported from a CDK/CloudFormation project.

## Overview

This project manages disaster recovery across an AWS Organization. It creates backup vaults, backup plans, cross-account copy jobs, AMI replication, ECR image mirroring, and Route 53 zone backups. Resources are spread across three deployment targets:

| Component | Account | Region(s) | Purpose |
|---|---|---|---|
| **backup-account** | Backup/DR account | `us-west-2` | Central backup vault, S3 bucket for Route 53 exports, KMS key, cross-account IAM role |
| **member-account** | Each member account | `eu-west-1`, `af-south-1`, `us-west-2` | Per-account backup vault, backup plan with cross-region copy, EventBridge forwarding rules |
| **devops-central** | DevOps account | `eu-west-1` | Lambda functions, SQS queues, CodeBuild project, EventBridge rules, CloudWatch alarms |

### How it works

```
Member Accounts                       DevOps Account                 Backup Account
(eu-west-1, af-south-1)              (eu-west-1)                    (us-west-2)
                                                                     
 AWS Backup Plan                                                     
   daily @ 00:00 UTC                                                 
   tag: backup=daily                                                 
       |                                                             
       v                                                             
 Copy to us-west-2 vault ----EventBridge----> copyBackup Lambda      
   (same account)                                  |                 
                                                   v                 
                                         StartCopyJob to ---------> Backup Vault
                                         backup account              (central DR)
                                                                     
 EC2 AMI events ----------EventBridge----> ec2ImageEventHandler      
                                                   |                 
                                              SQS (15m delay)       
                                                   |                 
                                                   v                 
                                          ec2ImageCopy Lambda        
                                           - Copy AMI to us-west-2  
                                           - Tag & share with org   
                                                                     
 ECR push/delete ---------EventBridge----> ecrImageEventHandler      
                                                   |                 
                                                   v                 
                                          CodeBuild project          
                                           - Pull image from source 
                                           - Push to backup region  
                                           - Push to backup account 
                                                                     
                          Schedule (daily)-> backupRoute53 Lambda    
                                           - Dump hosted zones -------> S3 Bucket
                                             as JSON                    (Route 53 backups)
```

## Directory Structure

```
.
├── terragrunt.hcl                 # Root config: remote state (S3+DynamoDB), provider generation
├── .gitignore
│
├── modules/
│   ├── backup-account/            # KMS, Vault, S3, IAM
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   │
│   ├── member-account/            # KMS, Vault, Backup Plan, IAM, EventBridge rules
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   │
│   └── devops-central/            # Lambdas, SQS, CodeBuild, EventBridge, CloudWatch
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
│
├── lambdas/                       # TypeScript Lambda source code
│   ├── build.sh                   # Build & package script
│   ├── package.json
│   ├── package-lock.json
│   ├── tsconfig.json
│   └── src/
│       ├── shared.ts              # SNS notification helper + asyncForEach utility
│       ├── backupRoute53.ts       # Scheduled: backs up Route 53 zones to S3
│       ├── copyBackup.ts          # EventBridge: copies backup recovery points to backup account
│       ├── ec2ImageEventHandler.ts# EventBridge: handles AMI create/deregister events
│       ├── ec2ImageCopy.ts        # SQS: deferred AMI copy, tag, and share
│       └── ecrImageEventHandler.ts# EventBridge: handles ECR image push/delete events
│
└── envs/
    ├── prod/
    │   ├── env.hcl                # Prod-wide variables (account IDs, org IDs, SNS topics)
    │   ├── backup-account/
    │   │   ├── env.hcl            # Region override → us-west-2
    │   │   └── us-west-2/
    │   │       └── terragrunt.hcl
    │   ├── devops-central/
    │   │   ├── env.hcl            # DevOps account config + Lambda-specific vars
    │   │   └── eu-west-1/
    │   │       └── terragrunt.hcl # Includes before_hook to build lambdas
    │   └── member-accounts/
    │       ├── env.hcl            # Shared member config
    │       ├── eu-west-1/
    │       │   ├── env.hcl        # Region override
    │       │   └── terragrunt.hcl # Primary region: full features
    │       ├── af-south-1/
    │       │   ├── env.hcl        # Region override
    │       │   └── terragrunt.hcl # Cape Town: no org-level perms
    │       └── us-west-2/
    │           ├── env.hcl        # Region override
    │           └── terragrunt.hcl # Backup region: vault only, no plan
    │
    └── systest/
        ├── env.hcl                # Systest-wide variables
        ├── devops-central/
        │   ├── env.hcl
        │   └── eu-west-1/
        │       └── terragrunt.hcl
        └── member-accounts/
            ├── env.hcl
            └── eu-west-1/
                ├── env.hcl
                └── terragrunt.hcl
```

## Prerequisites

- [Terraform](https://www.terraform.io/) >= 1.5 (or [OpenTofu](https://opentofu.org/))
- [Terragrunt](https://terragrunt.gruntwork.io/)
- [Node.js](https://nodejs.org/) >= 18 (for Lambda build)
- AWS CLI configured with credentials for the target account
- S3 bucket and DynamoDB table for Terraform remote state (created automatically by Terragrunt if the bucket doesn't exist)

## Configuration

All environment-specific values are defined in `env.hcl` files. Terragrunt uses `find_in_parent_folders("env.hcl")` to resolve the nearest `env.hcl`, so region-level files override component-level files which override environment-level files.

### Key variables

| Variable | Description | Example |
|---|---|---|
| `project` | Project identifier (lowercase) | `admin` |
| `environment` | Environment name (lowercase) | `prod`, `systest` |
| `aws_region` | AWS region for this deployment | `eu-west-1` |
| `devops_account_id` | Account running the Lambdas/CodeBuild | `555555555555` |
| `backup_account_id` | Central DR account with backup vault | `777777777777` |
| `backup_region` | Region for cross-region copies | `us-west-2` |
| `organization_id` | AWS Organization ID (for vault/S3 policies) | `o-pfayzcebx5` |
| `organization_arn` | AWS Organization ARN (for AMI sharing) | `arn:aws:organizations::...` |
| `devops_event_bus_arn` | EventBridge bus ARN in DevOps account | `arn:aws:events:eu-west-1:...:event-bus/default` |
| `general_notification_topic_arn` | SNS topic for general alerts | `arn:aws:sns:eu-west-1:...:...` |
| `critical_notification_topic_arn` | SNS topic for critical alerts | `arn:aws:sns:eu-west-1:...:...` |
| `ami_encryption_kms_key_arn` | KMS key/alias for encrypting copied AMIs | `arn:aws:kms:us-west-2:...:alias/...` |
| `route53_config` | Account IDs whose Route 53 zones to back up | `["888888888888"]` |

### Remote state

The root `terragrunt.hcl` configures S3 remote state:

- **Bucket**: `{project}-{environment}-terraform-state`
- **Key**: `backups/{path_relative_to_include}/terraform.tfstate`
- **Lock table**: `{project}-{environment}-terraform-locks`
- **Region**: Inherited from the nearest `env.hcl`

## Usage

### Building Lambda functions

The Lambda build runs automatically via Terragrunt's `before_hook` when you plan or apply the `devops-central` component. To build manually:

```bash
cd lambdas
bash build.sh
```

This produces `lambdas/lambda.zip` containing compiled JavaScript and production `node_modules`.

### Deploying a single component

```bash
# Deploy the backup account infrastructure
cd envs/prod/backup-account/us-west-2
terragrunt apply

# Deploy member-account resources for eu-west-1
cd envs/prod/member-accounts/eu-west-1
terragrunt apply

# Deploy the devops-central stack (auto-builds lambdas)
cd envs/prod/devops-central/eu-west-1
terragrunt apply
```

### Deploying all components in an environment

```bash
cd envs/prod
terragrunt run-all apply
```

### Planning changes

```bash
# Single component
cd envs/prod/devops-central/eu-west-1
terragrunt plan

# All components
cd envs/prod
terragrunt run-all plan
```

### Deploying to a specific member account

The member-account directory structure deploys to whichever AWS account your credentials target. To deploy to multiple member accounts in the same region, either:

1. **Switch credentials** between `terragrunt apply` runs (e.g., using `AWS_PROFILE` or `aws sts assume-role`), or
2. **Create per-account subdirectories** under the region directory:

```
envs/prod/member-accounts/eu-west-1/
├── account-111111111111/
│   ├── env.hcl
│   └── terragrunt.hcl
└── account-222222222222/
    ├── env.hcl
    └── terragrunt.hcl
```

### Destroying resources

```bash
# Single component
cd envs/prod/backup-account/us-west-2
terragrunt destroy

# All components (respects dependency order)
cd envs/prod
terragrunt run-all destroy
```

## Modules

### `backup-account`

Deployed once in the backup/DR account (`us-west-2`). Creates the central backup destination.

**Resources created:**
- KMS key with key rotation (for vault and S3 encryption)
- AWS Backup Vault with copy-job-failed notifications and org-wide access policy
- S3 bucket (versioned, KMS-encrypted, 180-day lifecycle) for Route 53 zone backups
- IAM cross-account role allowing the DevOps account to write backups, copy AMIs, and manage ECR images

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `project` | `string` | yes | | Project identifier (lowercase) |
| `environment` | `string` | yes | | Environment identifier (lowercase) |
| `devops_account_id` | `string` | yes | | DevOps account ID (allowed to assume cross-account role) |
| `organization_id` | `string` | yes | | Org ID for backup vault access policy |
| `production_ou_path` | `string` | yes | | OU path for S3 bucket read policy |
| `sns_topic_name` | `string` | no | `"devops-events-general"` | SNS topic name for vault notifications |
| `tags` | `map(string)` | no | `{}` | Tags for all resources |

| Output | Description |
|---|---|
| `kms_key_arn` | KMS key ARN |
| `kms_key_id` | KMS key ID |
| `backup_vault_name` | Vault name (`{project}-{env}-backups`) |
| `backup_vault_arn` | Vault ARN |
| `backup_bucket_name` | S3 bucket name (`{project}-{env}-backups-{region}`) |
| `backup_bucket_arn` | S3 bucket ARN |
| `cross_account_role_arn` | IAM role ARN for cross-account access |

### `member-account`

Deployed per-account and per-region across all member accounts. Uses boolean toggles to control which resources are created based on the region.

**Resources created:**
- KMS key (with Cape Town conditional logic for org-level permissions)
- AWS Backup Vault with copy-job-failed notifications
- AWS Backup Plan (daily at 00:00 UTC, 14-day retention, cross-region copy to `us-west-2`)
- AWS Backup Selection (tag-based: `backup=daily`)
- IAM role for backup selection (with S3 backup/restore policies)
- IAM role for EventBridge event forwarding (primary region only)
- EventBridge rules forwarding backup, EC2, and ECR events to DevOps account
- IAM cross-account role allowing DevOps to start copy jobs, copy AMIs, and manage ECR images (primary region only)

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `project` | `string` | yes | | Project identifier |
| `environment` | `string` | yes | | Environment identifier |
| `devops_account_id` | `string` | yes | | DevOps account ID |
| `backup_account_id` | `string` | yes | | Backup/DR account ID |
| `backup_region` | `string` | yes | | Backup copy destination region |
| `devops_event_bus_arn` | `string` | yes | | DevOps account EventBridge bus ARN |
| `sns_topic_name` | `string` | no | `"devops-events-general"` | SNS topic for vault notifications |
| `enable_backup_plan` | `bool` | no | `true` | Create backup plan (disable in backup region) |
| `enable_event_forwarding_role` | `bool` | no | `false` | Create EventBridge forwarding IAM role (primary region only) |
| `enable_cross_account_role` | `bool` | no | `false` | Create cross-account IAM role (primary region only) |
| `enable_backup_copy_event_forwarding` | `bool` | no | `true` | Forward backup copy events |
| `enable_ec2_event_forwarding` | `bool` | no | `true` | Forward EC2 AMI events |
| `enable_ecr_event_forwarding` | `bool` | no | `true` | Forward ECR image events |
| `is_cape_town` | `bool` | no | `false` | Disables org-level KMS/vault policies |
| `tags` | `map(string)` | no | `{}` | Tags for all resources |

**Region-specific toggle patterns:**

| Region | `enable_backup_plan` | `enable_event_forwarding_role` | `enable_cross_account_role` | Event forwarding | `is_cape_town` |
|---|---|---|---|---|---|
| `eu-west-1` (primary) | `true` | `true` | `true` | all enabled | `false` |
| `af-south-1` (Cape Town) | `true` | `false` | `false` | all enabled | `true` |
| `us-west-2` (backup region) | `false` | `false` | `false` | all disabled | `false` |

| Output | Description |
|---|---|
| `kms_key_arn` | KMS key ARN |
| `backup_vault_name` | Vault name |
| `backup_vault_arn` | Vault ARN |
| `backup_selection_role_arn` | Backup selection IAM role ARN |
| `cross_account_role_arn` | Cross-account role ARN (empty if not created) |

### `devops-central`

Deployed once in the DevOps account (`eu-west-1`). Orchestrates backup operations via Lambda functions.

**Resources created:**
- 5 Lambda functions (Node.js 18, TypeScript) with individual IAM roles
- SQS queue + dead-letter queue for deferred AMI copy processing
- CloudWatch alarms on DLQ messages and queue age
- EventBridge rules for backup copy events, EC2 AMI events, ECR image events, and a daily Route 53 backup schedule
- CodeBuild project for ECR image cross-account/cross-region copying (privileged mode for Docker)

**Lambda functions:**

| Function | Trigger | Purpose |
|---|---|---|
| `backupRoute53` | Schedule (daily 00:00 UTC) | Assumes role in each configured account, dumps Route 53 hosted zones to S3 in backup account |
| `copyBackup` | EventBridge (Copy Job State Change) | When a backup copy completes in a member account's `us-west-2` vault, copies the recovery point to the backup account vault |
| `ec2ImageEventHandler` | EventBridge (EC2 CopyImage/DeregisterImage) | On AMI creation: queues a deferred copy. On deregistration: deletes backup copies |
| `ec2ImageCopy` | SQS (15-minute delay) | Copies AMI to backup region, tags it, shares with org or backup account |
| `ecrImageEventHandler` | EventBridge (ECR Image Action) | On push: starts CodeBuild to replicate image. On delete: removes from backup account/region |

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `project` | `string` | yes | | Project identifier |
| `environment` | `string` | yes | | Environment identifier |
| `backup_account_id` | `string` | yes | | Backup/DR account ID |
| `backup_region` | `string` | yes | | Backup copy destination region |
| `general_notification_topic_arn` | `string` | yes | | SNS topic for general alerts |
| `critical_notification_topic_arn` | `string` | yes | | SNS topic for critical alerts |
| `route53_config` | `list(string)` | yes | | Account IDs for Route 53 backup |
| `route53_backup_role_arn` | `string` | yes | | IAM role ARN in backup account for Route 53 Lambda |
| `organization_arn` | `string` | yes | | Organization ARN for AMI sharing |
| `ami_encryption_kms_key_arn` | `string` | yes | | KMS key/alias for AMI encryption |
| `lambda_zip_path` | `string` | yes | | Path to built `lambda.zip` |
| `lambda_runtime` | `string` | no | `"nodejs18.x"` | Lambda runtime |
| `lambda_log_retention_days` | `number` | no | `7` | CloudWatch log retention |
| `tags` | `map(string)` | no | `{}` | Tags for all resources |

| Output | Description |
|---|---|
| `backup_events_queue_arn` | SQS queue ARN |
| `backup_events_queue_url` | SQS queue URL |
| `backup_events_dlq_arn` | Dead-letter queue ARN |
| `lambda_backup_route53_arn` | backupRoute53 Lambda ARN |
| `lambda_copy_backup_arn` | copyBackup Lambda ARN |
| `lambda_ec2_image_event_handler_arn` | ec2ImageEventHandler Lambda ARN |
| `lambda_ec2_image_copy_arn` | ec2ImageCopy Lambda ARN |
| `lambda_ecr_image_event_handler_arn` | ecrImageEventHandler Lambda ARN |
| `codebuild_project_name` | CodeBuild project name |

## Deployment Order

Components must be deployed in the following order due to cross-account dependencies:

1. **backup-account** -- Creates the vault, S3 bucket, and IAM role that other components reference.
2. **member-account** (all regions) -- Creates per-account vaults, backup plans, and cross-account roles that Lambdas assume.
3. **devops-central** -- Deploys the Lambda functions that assume roles in member and backup accounts.

When destroying, reverse the order.

## Environments

### prod

Fully configured with all three components across three regions:

- Backup account in `us-west-2`
- Member accounts in `eu-west-1` (primary), `af-south-1` (Cape Town), `us-west-2` (backup region)
- DevOps central in `eu-west-1`

### systest

Reduced deployment for testing:

- No backup account (the `backup_account_id` is not yet defined)
- Member accounts in `eu-west-1` only
- DevOps central in `eu-west-1`

> **Note:** The systest environment mirrors the original CDK project where `backupAccount` and `backupRegion` were not defined. Before deploying systest to production, populate `backup_account_id` in the systest `env.hcl` files.

## Adding a New Member Account

1. Ensure AWS credentials target the new member account.
2. Navigate to the desired region directory under `envs/<env>/member-accounts/<region>/`.
3. Run `terragrunt apply`.

If you need per-account state isolation (recommended for production), create account-specific subdirectories:

```
envs/prod/member-accounts/eu-west-1/
└── <account-id>/
    ├── env.hcl          # Same as parent env.hcl
    └── terragrunt.hcl   # Same as parent terragrunt.hcl, adjust source path
```

## Adding a New Region

1. Create a new region directory under `envs/<env>/member-accounts/<new-region>/`.
2. Create `env.hcl` with the `aws_region` set to the new region.
3. Create `terragrunt.hcl` with appropriate feature toggles (use `af-south-1` or `us-west-2` as a template depending on the region's role).
4. If the new region has org-level permission limitations (like Cape Town), set `is_cape_town = true`.

## Cape Town (af-south-1) Limitations

The `af-south-1` region does not support organization-level principals in:

- KMS key policies (the backup account service role statement is omitted)
- Backup vault access policies (the vault policy resource is not created)

These are controlled by the `is_cape_town` variable. The EventBridge forwarding role created in `eu-west-1` is referenced by ARN from Cape Town for event forwarding targets.

## Naming Conventions

Resources follow these naming patterns, where `project=admin` and `environment=prod`:

| Resource | Name Pattern | Example |
|---|---|---|
| KMS alias (backup account) | `alias/{project}-{env}-backups` | `alias/admin-prod-backups` |
| Backup vault (backup account) | `{project}-{env}-backups` | `admin-prod-backups` |
| S3 bucket (backup account) | `{project}-{env}-backups-{region}` | `admin-prod-backups-us-west-2` |
| KMS alias (member account) | `alias/{project}-{env}-backup` | `alias/admin-prod-backup` |
| Backup vault (member account) | `{project}-{env}-backup` | `admin-prod-backup` |
| Backup plan | `{project}-{env}-backups` | `admin-prod-backups` |
| Cross-account role | `{PROJECT}-{ENV}-BACKUP-CrossAccountBackupRole` | `ADMIN-PROD-BACKUP-CrossAccountBackupRole` |
| Backup selection role | `{PROJECT}-{ENV}-BACKUP-BackupSelectionRole-{region}` | `ADMIN-PROD-BACKUP-BackupSelectionRole-eu-west-1` |
| Event forwarding role | `{PROJECT}-{ENV}-backup-ForwardEvents` | `ADMIN-PROD-backup-ForwardEvents` |
| Lambda functions | `{PROJECT}-{ENV}-{functionName}` | `ADMIN-PROD-copyBackup` |
| SQS queues | `{PROJECT}-{ENV}-backupEvents` | `ADMIN-PROD-backupEvents` |
| CodeBuild project | `{PROJECT}-{ENV}-backup-ecrImageCopy` | `ADMIN-PROD-backup-ecrImageCopy` |

## Restoring from Backup

When restoring a backup, specify the regional `BackupSelectionRole`:

```
ADMIN-PROD-BACKUP-BackupSelectionRole-eu-west-1
```

The default AWS Backup service role does not have the S3 backup/restore permissions attached to the selection role.

## Requirements

| Tool | Version |
|---|---|
| Terraform / OpenTofu | >= 1.5 |
| AWS Provider | >= 5.0 |
| Terragrunt | any recent version |
| Node.js | >= 18 |
