# Bastion Host - Terraform/Terragrunt Deployment

Ported from CloudFormation templates (`template.json` and `efs-template.json`) to Terraform modules deployable via Terragrunt to multiple AWS accounts and regions.

## Overview

This role provisions a highly available bastion host behind an Auto Scaling Group with an encrypted EFS filesystem for persistent storage. It is split into two Terraform modules:

| Module | Purpose |
|--------|---------|
| `bastion-efs` | Encrypted EFS filesystem with KMS key and mount targets across AZs |
| `bastion` | EC2 bastion host: EIP, IAM role, security group, launch template, ASG, CloudWatch log groups/alarms, Cloud Map service discovery |

The `bastion` module depends on `bastion-efs` (needs the EFS filesystem ID).

## Directory Structure

```
bastion/
├── terragrunt.hcl                          # Root config (remote state, provider, common inputs)
├── .gitignore
├── README.md
├── _envcommon/
│   ├── bastion-efs.hcl                     # Shared config for bastion-efs component
│   └── bastion.hcl                         # Shared config for bastion component
├── modules/
│   ├── bastion-efs/
│   │   ├── main.tf                         # EFS, KMS key, security group, mount targets
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── bastion/
│       ├── main.tf                         # EIP, IAM, SG, launch template, ASG, logs, alarm, service discovery
│       ├── variables.tf
│       └── outputs.tf
├── envs/
│   ├── systest/                            # Single-account environment
│   │   ├── env.hcl                         # Environment variables
│   │   └── eu-west-1/
│   │       ├── bastion-efs/
│   │       │   └── terragrunt.hcl
│   │       └── bastion/
│   │           └── terragrunt.hcl
│   └── prodire/                            # Multi-account environment
│       ├── env.hcl                         # Environment variables + target_ou_ids + target_regions
│       ├── eu-west-1/
│       │   ├── bastion-efs/
│       │   │   └── terragrunt.hcl
│       │   └── bastion/
│       │       └── terragrunt.hcl
│       └── af-south-1/
│           ├── bastion-efs/
│           │   └── terragrunt.hcl
│           └── bastion/
│               └── terragrunt.hcl
└── scripts/
    └── generate_account_dirs.sh            # Auto-scaffold per-account directories from OUs
```

### Multi-Account Layout (after running generate_account_dirs.sh)

For multi-account environments like `prodire`, the script creates per-account directories:

```
envs/prodire/eu-west-1/
├── bastion-efs/                            # Direct (non-account-specific) deployment
│   └── terragrunt.hcl
├── bastion/
│   └── terragrunt.hcl
├── 111111111111/                           # Per-account deployment
│   ├── account.hcl                         # Account ID + name override
│   ├── bastion-efs/
│   │   └── terragrunt.hcl
│   └── bastion/
│       └── terragrunt.hcl
└── 222222222222/
    ├── account.hcl
    ├── bastion-efs/
    │   └── terragrunt.hcl
    └── bastion/
        └── terragrunt.hcl
```

## Resources Created

### bastion-efs module

| Resource | Description |
|----------|-------------|
| `aws_security_group.efs` | Allows NFS (2049) from VPC CIDR |
| `aws_kms_key.efs` | KMS key for EFS encryption (key rotation enabled) |
| `aws_kms_alias.efs` | Alias for the KMS key |
| `aws_efs_file_system.bastion` | General-purpose encrypted EFS filesystem |
| `aws_efs_backup_policy.bastion` | Automatic backups enabled |
| `aws_efs_mount_target.bastion[]` | One mount target per public subnet/AZ |

### bastion module

| Resource | Description |
|----------|-------------|
| `aws_eip.bastion` | Elastic IP for stable public address |
| `aws_iam_role.bastion` | EC2 instance role with SSM managed policy |
| `aws_iam_role_policy.standard` | SNS publish, SSM params, S3 access, CloudWatch logs/metrics |
| `aws_iam_role_policy.bastion` | EIP association, EC2 describe, Route53, service discovery |
| `aws_iam_instance_profile.bastion` | Instance profile linking role to EC2 |
| `aws_security_group.bastion` | SSH (configurable port), Icinga (5665-5666), OpenTelemetry (4317) |
| `aws_launch_template.bastion` | IMDSv2 required, public IP, UserData with env exports |
| `aws_cloudwatch_log_group.bastion[]` | 8 log groups (syslog, auth, secure, audit, aide, etc.) |
| `aws_autoscaling_group.bastion` | Min/max 1 instance, rolling refresh, multi-AZ |
| `aws_autoscaling_notification.bastion` | SNS notifications for launch/terminate errors |
| `aws_cloudwatch_metric_alarm.high_cpu` | Alarm when CPU > threshold for 5 minutes |
| `aws_service_discovery_service.bastion` | Cloud Map "bastion" A-record service |

## CloudFormation to Terraform Mapping

| CloudFormation Resource | Terraform Resource |
|------------------------|-------------------|
| `AWS::EC2::EIP` | `aws_eip.bastion` |
| `AWS::IAM::Role` | `aws_iam_role.bastion` + `aws_iam_role_policy.*` |
| `AWS::IAM::InstanceProfile` | `aws_iam_instance_profile.bastion` |
| `AWS::EC2::SecurityGroup` (bastion) | `aws_security_group.bastion` |
| `AWS::EC2::LaunchTemplate` | `aws_launch_template.bastion` |
| `AWS::Logs::LogGroup` (x8) | `aws_cloudwatch_log_group.bastion` (for_each) |
| `AWS::AutoScaling::AutoScalingGroup` | `aws_autoscaling_group.bastion` |
| `AWS::CloudWatch::Alarm` | `aws_cloudwatch_metric_alarm.high_cpu` |
| `AWS::ServiceDiscovery::Service` | `aws_service_discovery_service.bastion` |
| `AWS::EC2::SecurityGroup` (EFS) | `aws_security_group.efs` |
| `AWS::KMS::Key` | `aws_kms_key.efs` |
| `AWS::EFS::FileSystem` | `aws_efs_file_system.bastion` |
| `AWS::EFS::MountTarget` (x3) | `aws_efs_mount_target.bastion[]` |

### Key Differences from CloudFormation

- **AZ handling**: CloudFormation used `Conditions` (`TwoAZStack`/`ThreeAZStack`) to conditionally create mount targets and subnets. Terraform uses `count = length(var.public_subnet_ids)` - simply pass the subnets you have and it creates the right number of resources.
- **Log groups**: CloudFormation defined 8 separate resources. Terraform uses `for_each` over a list for cleaner code.
- **Security group ingress**: CloudFormation had hardcoded CIDR blocks for VPN servers. Terraform uses `dynamic` blocks with a `vpn_cidrs` variable for configurability.
- **Hosted zone mapping**: CloudFormation used a `Mappings` section. Terraform accepts `hosted_zone_id` and `route53_zone_ids` directly as variables.
- **Multi-account**: CloudFormation relied on StackSets for cross-account deployment. Terragrunt uses a directory-per-account pattern with `assume_role` provider generation.

## Configuration

### Environment Variables (env.hcl)

Each environment has an `env.hcl` file with all configuration. Key variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `project` | Project identifier | `devops` |
| `service` | Service name | `bastion` |
| `environment` | Environment name | `systest`, `prodire` |
| `account_id` | Default AWS account ID | `000000000000` |
| `vpc_id` | VPC ID | `vpc-xxxxxxxxx` |
| `vpc_cidr` | VPC CIDR block | `10.0.0.0/16` |
| `public_subnet_ids` | Public subnets for ASG/EFS | `["subnet-xxx", ...]` |
| `ami_id` | AMI for bastion instances | `ami-xxxxxxxxx` |
| `instance_type` | EC2 instance type | `t3.micro` |
| `ssh_port` | SSH port | `22` |
| `vpn_cidrs` | VPN server CIDRs for SSH access | `[{cidr, description}]` |
| `icinga_ips` | Icinga monitoring server IPs | `["x.x.x.x"]` |
| `cpu_warning_threshold` | CPU alarm threshold (%) | `80` |
| `log_retention_days` | CloudWatch log retention | `180` |
| `sns_topic_arns` | SNS topics [critical, general] | `["arn:aws:sns:..."]` |
| `project_bucket_arn` | Project S3 bucket ARN | `arn:aws:s3:::...` |
| `project_bucket_name` | Project S3 bucket name | `devops-systest-...` |
| `authorized_users_bucket` | S3 bucket for authorized keys | `moya-internal` |
| `hosted_zone_id` | Route53 zone for this environment | `Z000...` |
| `route53_zone_ids` | All Route53 zones bastion may manage | `["Z000...", ...]` |
| `service_discovery_namespace_id` | Cloud Map namespace ID | `ns-xxxxxxxxx` |
| `git_repo_url` | Git repo for instance init | `git@github.com:...` |

For multi-account environments, additionally:

| Variable | Description |
|----------|-------------|
| `target_ou_ids` | AWS Organizations OU IDs to discover accounts from |
| `target_regions` | AWS regions to deploy to |

## Deployment

### Prerequisites

- Terraform >= 1.5.0
- Terragrunt
- AWS CLI v2 (for `generate_account_dirs.sh`)
- AWS credentials with:
  - `sts:AssumeRole` to the target account's terraform execution role
  - `organizations:ListAccountsForParent` (for account discovery script)

### Single-Account Deployment (systest)

```bash
# Deploy EFS first (bastion depends on it)
cd envs/systest/eu-west-1/bastion-efs
terragrunt plan
terragrunt apply

# Then deploy bastion
cd ../bastion
terragrunt plan
terragrunt apply

# Or deploy both with dependency resolution
cd envs/systest/eu-west-1
terragrunt run-all plan
terragrunt run-all apply
```

### Multi-Account Deployment (prodire)

```bash
# 1. Generate per-account directories from AWS Organizations OUs
./scripts/generate_account_dirs.sh prodire

# 2. Review what was generated
find envs/prodire -name account.hcl

# 3. Deploy all accounts and regions
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply

# Or deploy a specific account/region
cd envs/prodire/eu-west-1/111111111111/bastion
terragrunt plan
terragrunt apply
```

### Adding a New Environment

1. Create `envs/<new-env>/env.hcl` with all required variables
2. Create region directories under `envs/<new-env>/<region>/`
3. Add `bastion-efs/terragrunt.hcl` and `bastion/terragrunt.hcl` leaf files
4. For multi-account: add `target_ou_ids` and `target_regions` to `env.hcl`, then run `./scripts/generate_account_dirs.sh <new-env>`

### Adding a New Region to an Existing Environment

1. Create `envs/<env>/<new-region>/bastion-efs/terragrunt.hcl` and `envs/<env>/<new-region>/bastion/terragrunt.hcl`
2. For multi-account: add the region to `target_regions` in `env.hcl` and re-run `./scripts/generate_account_dirs.sh <env>`

## How It Works

### Terragrunt Config Resolution

1. **Root `terragrunt.hcl`** parses the filesystem path to determine environment and region. It generates:
   - S3 backend config (per-account state bucket)
   - AWS provider with `assume_role` into the target account
   - Terraform version constraints

2. **`_envcommon/*.hcl`** files point to the Terraform module source and pass environment-level inputs from `env.hcl`.

3. **Leaf `terragrunt.hcl`** files include both root and envcommon configs. The bastion leaf also declares a `dependency` on `bastion-efs` to get the EFS filesystem ID.

4. **`account.hcl`** (optional, auto-generated) overrides the default `account_id` from `env.hcl` for multi-account deployments. The root `terragrunt.hcl` uses `try()` to prefer `account.hcl` when present.

### Account Discovery (generate_account_dirs.sh)

The script bridges AWS Organizations OU-based targeting (which CloudFormation StackSets handled natively) with Terragrunt's directory-per-account model:

1. Reads `target_ou_ids` and `target_regions` from the environment's `env.hcl`
2. Queries `aws organizations list-accounts-for-parent` for each OU
3. For each active account + region combination, scaffolds:
   - `account.hcl` with the account ID and name
   - `bastion-efs/terragrunt.hcl` leaf
   - `bastion/terragrunt.hcl` leaf (with EFS dependency)
4. Skips directories that already exist (safe to re-run)

### Remote State

State is stored per-account in S3:
- Bucket: `<project>-<environment>-tfstate-<account_id>`
- Key: `bastion/<path>/terraform.tfstate`
- Locking: DynamoDB table `<project>-<environment>-tfstate-lock`

### Provider

The AWS provider assumes a role `<project>-terraform-execution` in the target account. This role must exist in each target account and trust the account running Terragrunt.
