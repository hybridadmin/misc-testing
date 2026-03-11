# Redis EFS - Elastic File System Terraform Module

Terragrunt-managed Terraform module for deploying encrypted AWS EFS filesystems
for Redis persistence across multiple accounts and regions.

**Ported from:** Ansible + CloudFormation (`roles/redisefs/files/template.json`)

## Architecture

```
                     ┌─────────────────────────────────────────┐
                     │              AWS Account                │
                     │                                         │
                     │  ┌──────────────────────────────────┐   │
                     │  │           VPC                     │   │
                     │  │                                   │   │
                     │  │  ┌─────────┐  NFS/2049            │   │
                     │  │  │   SG    │◄──── (VPC CIDR)      │   │
                     │  │  └────┬────┘                      │   │
                     │  │       │                            │   │
                     │  │  ┌────▼────┐                      │   │
                     │  │  │   EFS   │ encrypted (KMS)      │   │
                     │  │  │  File   │ backup DISABLED      │   │
                     │  │  │ System  │ generalPurpose       │   │
                     │  │  │         │ IA after 1 day       │   │
                     │  │  └────┬────┘                      │   │
                     │  │       │                            │   │
                     │  │  ┌────┴──────────────────────┐    │   │
                     │  │  │    Mount Targets           │    │   │
                     │  │  │  ┌──────┐ ┌──────┐ ┌────┐ │    │   │
                     │  │  │  │ AZ-1 │ │ AZ-2 │ │AZ-n│ │    │   │
                     │  │  │  └──────┘ └──────┘ └────┘ │    │   │
                     │  │  └───────────────────────────┘    │   │
                     │  │   (private subnets)                │   │
                     │  └──────────────────────────────────┘   │
                     └─────────────────────────────────────────┘
```

## Resources Created

| Resource | Description |
|----------|-------------|
| `aws_security_group` | Allows NFS (TCP 2049) from VPC CIDR |
| `aws_kms_key` + `aws_kms_alias` | Customer-managed key for EFS encryption at rest with key rotation enabled |
| `aws_efs_file_system` | General-purpose encrypted EFS with lifecycle policy (IA after 1 day) |
| `aws_efs_backup_policy` | Automatic backup **disabled** (Redis manages its own persistence) |
| `aws_efs_mount_target` | One per private subnet (scales to any AZ count) |

## Differences from Generic EFS Module

| Feature | Generic EFS (`roles/efs`) | Redis EFS (`roles/redisefs`) |
|---------|--------------------------|------------------------------|
| Lifecycle policy | None | Transition to IA after 1 day |
| Backup policy | Enabled | **Disabled** |
| Naming convention | `*-EFS-*` | `*-REDIS-EFS-*` |
| KMS alias | `*-efs` | `*-redis-efs` |

## Project Structure

```
redisefs/
├── terragrunt.hcl                    # Root config: remote state, provider, common inputs
├── _envcommon/
│   └── redisefs.hcl                  # Shared component config (module source, env inputs)
├── modules/
│   └── redisefs/
│       ├── main.tf                   # Terraform resources
│       ├── variables.tf              # Module input variables
│       └── outputs.tf                # Module outputs
├── envs/
│   ├── systest/                      # Single-account environment
│   │   ├── env.hcl                   # Environment variables
│   │   └── eu-west-1/
│   │       └── redisefs/
│   │           └── terragrunt.hcl    # Leaf deployment
│   └── prodire/                      # Multi-account environment
│       ├── env.hcl                   # Environment variables + target OUs/regions
│       ├── eu-west-1/
│       │   └── redisefs/
│       │       └── terragrunt.hcl    # Leaf deployment (default account)
│       └── af-south-1/
│           └── redisefs/
│               └── terragrunt.hcl    # Leaf deployment (default account)
├── scripts/
│   └── generate_account_dirs.sh      # OU account discovery + dir scaffolding
├── .gitignore
└── README.md
```

### Multi-Account Directory Layout (after running generate_account_dirs.sh)

```
envs/prodire/
├── env.hcl
├── eu-west-1/
│   ├── redisefs/
│   │   └── terragrunt.hcl           # Default account deployment
│   ├── 111111111111/
│   │   ├── account.hcl              # Account-specific overrides
│   │   └── redisefs/
│   │       └── terragrunt.hcl       # Per-account deployment
│   └── 222222222222/
│       ├── account.hcl
│       └── redisefs/
│           └── terragrunt.hcl
└── af-south-1/
    ├── redisefs/
    │   └── terragrunt.hcl
    ├── 111111111111/
    │   ├── account.hcl
    │   └── redisefs/
    │       └── terragrunt.hcl
    └── ...
```

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI** v2 (for `generate_account_dirs.sh`)
- **jq** (for `generate_account_dirs.sh`)
- An IAM role `<project>-terraform-execution` in each target account that Terragrunt can assume
- S3 bucket and DynamoDB table for remote state (per account)
- An existing VPC with private subnets in the target account/region

## Configuration

### Environment Variables (`env.hcl`)

| Variable | Type | Description |
|----------|------|-------------|
| `project` | `string` | Project identifier (e.g. `devops`) |
| `service` | `string` | Service identifier (always `redisefs`) |
| `environment` | `string` | Environment name (e.g. `systest`, `prodire`) |
| `account_id` | `string` | Default AWS account ID (overridden per-account in multi-account mode) |
| `vpc_id` | `string` | VPC ID where EFS will be deployed |
| `vpc_cidr` | `string` | VPC CIDR block for NFS security group ingress |
| `private_subnet_ids` | `list(string)` | Private subnet IDs for mount targets (one per AZ) |

#### Multi-Account Only

| Variable | Type | Description |
|----------|------|-------------|
| `target_ou_ids` | `list(string)` | AWS Organizations OU IDs to enumerate accounts from |
| `target_regions` | `list(string)` | AWS regions to deploy into |

### Module Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project` | `string` | - | Project identifier |
| `environment` | `string` | - | Deployment environment |
| `service` | `string` | `"redisefs"` | Service identifier |
| `aws_region` | `string` | - | AWS region |
| `vpc_id` | `string` | - | VPC ID for security group |
| `vpc_cidr` | `string` | - | VPC CIDR for NFS ingress |
| `private_subnet_ids` | `list(string)` | - | Subnet IDs for mount targets |
| `tags` | `map(string)` | `{}` | Additional tags |

### Module Outputs

| Output | Description |
|--------|-------------|
| `efs_id` | EFS filesystem ID |
| `efs_arn` | EFS filesystem ARN |
| `efs_dns_name` | EFS filesystem DNS name |
| `security_group_id` | Security group ID for EFS |
| `kms_key_arn` | KMS key ARN used for encryption |
| `kms_key_id` | KMS key ID used for encryption |
| `mount_target_ids` | List of mount target IDs |
| `mount_target_dns_names` | List of mount target DNS names |

## Deployment

### Single Account (systest)

```bash
# Plan
cd envs/systest/eu-west-1/redisefs
terragrunt plan

# Apply
terragrunt apply
```

### Single Region, All Accounts (prodire)

```bash
# Plan all deployments in eu-west-1
cd envs/prodire/eu-west-1
terragrunt run-all plan

# Apply all
terragrunt run-all apply
```

### All Regions, All Accounts

```bash
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply
```

### Specific Account in Multi-Account Mode

```bash
cd envs/prodire/eu-west-1/111111111111/redisefs
terragrunt plan
terragrunt apply
```

## Multi-Account Setup

### 1. Configure Target OUs and Regions

Edit `envs/<environment>/env.hcl` and set the `target_ou_ids` and `target_regions`:

```hcl
locals {
  # ...
  target_ou_ids = [
    "ou-xxxx-aaaaaaaa", # Production Accounts OU
    "ou-xxxx-bbbbbbbb", # Development Accounts OU
  ]

  target_regions = [
    "eu-west-1",
    "af-south-1",
  ]
}
```

### 2. Generate Account Directories

```bash
./scripts/generate_account_dirs.sh prodire
```

This queries AWS Organizations for all active accounts in the target OUs and
creates the directory structure with `account.hcl` and leaf `terragrunt.hcl`
files for each account/region combination. Existing directories are skipped.

### 3. Customize Per-Account Networking

Each account will likely have its own VPC. Override the networking inputs in
the generated leaf `terragrunt.hcl`:

```hcl
inputs = {
  vpc_id             = "vpc-xxxxxxxxxxxxxxxxx"
  vpc_cidr           = "10.1.0.0/16"
  private_subnet_ids = ["subnet-aaa", "subnet-bbb"]
}
```

Alternatively, use Terraform data sources in the module to look up the VPC
and subnets dynamically by tags.

### 4. Deploy

```bash
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply
```

## Remote State Layout

State is stored per-account in S3:

```
Bucket: <project>-<environment>-tfstate-<account_id>
Key:    redisefs/<region>/terraform.tfstate
Lock:   <project>-<environment>-tfstate-lock (DynamoDB)
```

Example:
```
Bucket: devops-prodire-tfstate-111111111111
Key:    redisefs/eu-west-1/terraform.tfstate
```

## IAM Permissions Required

The `<project>-terraform-execution` role assumed by Terragrunt needs:

| Service | Actions |
|---------|---------|
| EFS | `elasticfilesystem:*` |
| EC2 | `ec2:CreateSecurityGroup`, `ec2:DeleteSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:RevokeSecurityGroupIngress`, `ec2:DescribeSecurityGroups`, `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:CreateTags`, `ec2:DeleteTags` |
| KMS | `kms:CreateKey`, `kms:CreateAlias`, `kms:DeleteAlias`, `kms:DescribeKey`, `kms:EnableKeyRotation`, `kms:GetKeyPolicy`, `kms:GetKeyRotationStatus`, `kms:ListAliases`, `kms:PutKeyPolicy`, `kms:ScheduleKeyDeletion`, `kms:TagResource`, `kms:UntagResource` |
| S3 | Read/write to the tfstate bucket |
| DynamoDB | Read/write to the tfstate-lock table |

For `generate_account_dirs.sh`, the caller needs:

| Service | Actions |
|---------|---------|
| Organizations | `organizations:ListAccountsForParent` |

## Adding a New Environment

1. Create the environment directory:
   ```bash
   mkdir -p envs/<new-env>/
   ```

2. Create `envs/<new-env>/env.hcl` with environment-specific variables (use
   `envs/systest/env.hcl` as a template for single-account, or
   `envs/prodire/env.hcl` for multi-account).

3. Create region/component directories:
   ```bash
   mkdir -p envs/<new-env>/<region>/redisefs
   ```

4. Create a leaf `terragrunt.hcl` (copy from an existing environment).

5. For multi-account, run the scaffolding script:
   ```bash
   ./scripts/generate_account_dirs.sh <new-env>
   ```

## Adding a New Region

1. Add the region to `target_regions` in `env.hcl` (for documentation and
   script usage).

2. Create the region directory:
   ```bash
   mkdir -p envs/<env>/<new-region>/redisefs
   ```

3. Copy or create a leaf `terragrunt.hcl`.

4. For multi-account, re-run the scaffolding script -- it skips existing
   directories and only creates new ones:
   ```bash
   ./scripts/generate_account_dirs.sh <env>
   ```

## Porting Notes (CloudFormation to Terraform)

| CloudFormation | Terraform |
|----------------|-----------|
| `AWS::EC2::SecurityGroup` | `aws_security_group.efs` |
| `AWS::KMS::Key` | `aws_kms_key.efs` + `aws_kms_alias.efs` |
| `AWS::EFS::FileSystem` (with `LifecyclePolicies`) | `aws_efs_file_system.this` (with `lifecycle_policy` block) |
| `AWS::EFS::FileSystem` `BackupPolicy: DISABLED` | `aws_efs_backup_policy.this` with `status = "DISABLED"` |
| `AWS::EFS::MountTarget` x3 (conditional) | `aws_efs_mount_target.this` (count-based, any number of AZs) |
| `Fn::ImportValue` for VPC/subnet cross-stack refs | Explicit `vpc_id`, `vpc_cidr`, `private_subnet_ids` input variables |
| `Conditions.ThreeAZStack` | Eliminated -- `count = length(var.private_subnet_ids)` handles any AZ count |
| Stack outputs with `Export` | Terraform outputs consumable via `terraform_remote_state` or Terragrunt `dependency` blocks |

### Key Improvements Over Original

- **KMS key rotation** enabled (not in the original CloudFormation template)
- **KMS alias** added for easier key identification
- **Dynamic AZ count** -- no hardcoded 2/3 AZ conditional; handles any number of subnets
- **Multi-account support** -- deploy to any number of AWS accounts via Terragrunt directory structure
- **Multi-region support** -- deploy to any combination of AWS regions
- **Remote state isolation** -- each account gets its own S3 state bucket
- **Tag consistency** -- default tags applied via provider + resource-level tags
