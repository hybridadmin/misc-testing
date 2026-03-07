# ECR Governance - Terraform / Terragrunt

Automated ECR repository governance deployed via Terraform modules and Terragrunt across multiple AWS accounts and regions.

When a new ECR repository is created in any target account, EventBridge detects the `CreateRepository` CloudTrail event and triggers Lambda functions that automatically apply:

1. **Cross-account repository policies** -- grants image pull/push access to configured AWS accounts
2. **Lifecycle policies** (optional) -- expires images when count exceeds a configurable threshold

Ported from the original CDK-based `devops-utilities-ecr` project.

## Architecture

```
Developer creates ECR repository (Console / CLI / API / IaC)
        |
        v
CloudTrail captures "CreateRepository" API call
        |
        v
EventBridge Rule matches the event
        |
        v
Lambda "Add-Permissions"          Lambda "Attach-LifecyclePolicy"
(always active)                   (controlled by enable_lifecycle_policy flag)
        |                                    |
        v                                    v
Sets cross-account repo policy    Sets lifecycle policy
(pull/push per env config)        (max N images, configurable)
```

## Directory Structure

```
ecr/
├── terragrunt.hcl                          # Root config: remote state, provider, common inputs
├── _envcommon/
│   └── ecr-governance.hcl                  # Shared module source + common inputs
├── modules/
│   └── ecr-governance/
│       ├── main.tf                         # Terraform resources (Lambdas, IAM, EventBridge, Logs)
│       ├── variables.tf                    # Input variables
│       └── outputs.tf                      # Output values
├── src/
│   ├── add_permissions.py                  # Lambda: cross-account ECR repository policies
│   └── attach_policy.py                    # Lambda: ECR lifecycle policies
├── envs/
│   ├── prodire/                            # Production Ireland (multi-account)
│   │   ├── env.hcl                         # Environment variables, target OUs, regions
│   │   ├── eu-west-1/
│   │   │   └── ecr-governance/
│   │   │       └── terragrunt.hcl          # Leaf: default account deployment
│   │   └── af-south-1/
│   │       └── ecr-governance/
│   │           └── terragrunt.hcl          # Leaf: default account deployment
│   └── systest/                            # System test (single account)
│       ├── env.hcl                         # Environment variables
│       └── eu-west-1/
│           └── ecr-governance/
│               └── terragrunt.hcl          # Leaf: single account deployment
├── scripts/
│   └── generate_account_dirs.sh            # Auto-scaffolds per-account directories from OUs
└── README.md
```

After running `generate_account_dirs.sh`, multi-account directories are added:

```
envs/prodire/eu-west-1/
├── ecr-governance/terragrunt.hcl           # Default account
├── 123456789012/                           # Per-account (auto-generated)
│   ├── account.hcl                         # Account ID + name override
│   └── ecr-governance/
│       └── terragrunt.hcl                  # Leaf deployment
├── 234567890123/
│   ├── account.hcl
│   └── ecr-governance/
│       └── terragrunt.hcl
...
```

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI v2** configured with credentials that can:
  - Assume `<project>-terraform-execution` role in target accounts
  - Call `organizations:ListAccountsForParent` (for the generate script)
- **jq** (for the generate script)

## AWS Resources Created Per Account/Region

| Resource | Name Pattern | Purpose |
|---|---|---|
| IAM Role | `<PROJECT>-<ENV>-ECR-Lambda-Role` | Shared execution role for both Lambdas |
| IAM Policies (x3) | `-LambdaLogs`, `-LambdaECR`, `-LambdaSSM` | CloudWatch Logs, ECR, SSM access |
| Lambda Function | `<PROJECT>-<ENV>-ECR-Add-Permissions` | Applies cross-account repository policies |
| Lambda Function | `<PROJECT>-<ENV>-ECR-Attach-LifecyclePolicy` | Applies lifecycle policies |
| CloudWatch Log Group (x2) | `/aws/lambda/<function-name>` | Lambda execution logs |
| EventBridge Rule | `<PROJECT>-<ENV>-ECR-CreateRepository` | Triggers on ECR CreateRepository |
| EventBridge Target(s) | - | Routes events to Lambda(s) |
| Lambda Permission(s) | - | Allows EventBridge to invoke Lambda(s) |

## Configuration

### Environment Variables (`env.hcl`)

| Variable | Type | Description |
|---|---|---|
| `project` | string | Project identifier (e.g. `devops`) |
| `service` | string | Service name (always `ecr`) |
| `environment` | string | Environment name (e.g. `prodire`, `systest`) |
| `account_id` | string | Default AWS account ID (overridden per-account via `account.hcl`) |
| `log_retention_days` | number | CloudWatch Log Group retention (days) |
| `enable_lifecycle_policy` | bool | Enable automatic lifecycle policy attachment |
| `lifecycle_max_image_count` | number | Max images before lifecycle policy expires old ones |
| `ecr_pull_account_ids` | list(string) | AWS account IDs granted ECR image pull access |
| `ecr_push_account_ids` | list(string) | AWS account IDs granted ECR image push access |
| `target_ou_ids` | list(string) | AWS Organizations OU IDs (used by generate script) |
| `target_regions` | list(string) | Target AWS regions (used by generate script) |

### Key Design Decisions

- **Account IDs are externalized** -- the Lambda functions read `PULL_ACCOUNT_IDS` and `PUSH_ACCOUNT_IDS` from environment variables (JSON arrays), configured via Terraform variables. No account IDs are hardcoded in source code.
- **Lifecycle policy is opt-in** -- controlled by the `enable_lifecycle_policy` flag in `env.hcl`. When `false`, the Lambda is still deployed but is not wired to EventBridge.
- **Account resolution** -- the root `terragrunt.hcl` tries to load `account.hcl` from the parent directory. If found, it uses that account ID; otherwise falls back to the default in `env.hcl`.

## Deployment

### Single Account (systest)

```bash
# Plan
cd envs/systest/eu-west-1/ecr-governance
terragrunt plan

# Apply
terragrunt apply
```

### Multi-Account Setup (prodire)

#### Step 1: Generate account directories from AWS Organizations

```bash
# Ensure AWS credentials can call organizations:ListAccountsForParent
./scripts/generate_account_dirs.sh prodire
```

This queries the OUs defined in `envs/prodire/env.hcl` and creates per-account directories with `account.hcl` and leaf `terragrunt.hcl` files.

#### Step 2: Plan all accounts in an environment

```bash
cd envs/prodire
terragrunt run-all plan
```

#### Step 3: Apply all accounts in an environment

```bash
cd envs/prodire
terragrunt run-all apply
```

#### Deploy a single account/region

```bash
cd envs/prodire/eu-west-1/123456789012/ecr-governance
terragrunt plan
terragrunt apply
```

### Adding a New Environment

1. Create `envs/<new-env>/env.hcl` with the required variables (copy from `systest` or `prodire` as a starting point)
2. Create region directories: `envs/<new-env>/<region>/ecr-governance/`
3. Add a leaf `terragrunt.hcl` in each:

```hcl
include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/ecr-governance.hcl"
  expose = true
}

inputs = {}
```

4. For multi-account environments, add `target_ou_ids` and `target_regions` to `env.hcl` and run `generate_account_dirs.sh`.

### Adding a New Region

For an existing environment, create the region directory with a leaf `terragrunt.hcl`:

```bash
mkdir -p envs/prodire/us-east-1/ecr-governance
```

Copy an existing leaf `terragrunt.hcl` into it. For multi-account, also add the region to `target_regions` in `env.hcl` and re-run `generate_account_dirs.sh`.

## Remote State

State is stored per-account in S3:

| Component | Value |
|---|---|
| Bucket | `<project>-<environment>-tfstate-<account_id>` |
| Key | `ecr/<region>/terraform.tfstate` |
| DynamoDB Table | `<project>-<environment>-tfstate-lock` |
| Encryption | Enabled |

## Provider Configuration

Terragrunt generates the AWS provider to assume a role in each target account:

```
arn:aws:iam::<account_id>:role/<project>-terraform-execution
```

This role must exist in every target account and trust the account/role running Terragrunt.

## Changes from Original CDK Project

| Aspect | Original (CDK) | Ported (Terraform/Terragrunt) |
|---|---|---|
| IaC tool | AWS CDK (TypeScript) | Terraform + Terragrunt |
| Deployment scope | Single account/region | Multi-account, multi-region |
| Account IDs | Hardcoded in Python Lambda source | Passed via environment variables from Terraform |
| Lifecycle policy | Existed but was disabled (commented out target) | Opt-in via `enable_lifecycle_policy` flag |
| ECR permissions | IAM policy used `*` for all ECR repos | Scoped to `arn:aws:ecr:<region>:<account>:repository/*` |
| Lambda runtime | Python 3.12, x86_64 implied | Python 3.12, arm64 default (configurable) |
| State management | CloudFormation | S3 + DynamoDB (per-account buckets) |

## Destroying Resources

```bash
# Single account
cd envs/systest/eu-west-1/ecr-governance
terragrunt destroy

# All accounts in an environment
cd envs/prodire
terragrunt run-all destroy
```

## Sample CloudTrail Event (for testing)

The Lambda functions are triggered by CloudTrail events matching this pattern:

```json
{
  "version": "0",
  "id": "12345678-1234-1234-1234-123456789012",
  "detail-type": "AWS API Call via CloudTrail",
  "source": "aws.ecr",
  "account": "123456789012",
  "time": "2025-01-01T12:00:00Z",
  "region": "eu-west-1",
  "detail": {
    "eventSource": "ecr.amazonaws.com",
    "eventName": "CreateRepository",
    "awsRegion": "eu-west-1",
    "requestParameters": {
      "repositoryName": "my-new-repo"
    }
  }
}
```
