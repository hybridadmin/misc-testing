# LogsAlarm - CloudWatch Alarm Log Enrichment

Deploys an AWS Lambda function across multiple accounts and regions using Terragrunt. When a CloudWatch alarm transitions to the **ALARM** state, the Lambda checks whether the alarm is based on a metric filter. If so, it fetches the last 5 minutes of log events from the associated CloudWatch Log Group and publishes them to the alarm's SNS notification topic(s). This gives operators immediate context -- not just "alarm fired", but the actual log lines that triggered it.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    Target AWS Account (per OU)                   │
│                                                                  │
│  ┌──────────────┐    CloudWatch Alarm     ┌───────────────────┐  │
│  │  CloudWatch   │──── State Change ──────▶│  EventBridge Rule │  │
│  │  Alarm        │    (detail.state=ALARM) │  handleLogsAlarm  │  │
│  └──────┬───────┘                         └────────┬──────────┘  │
│         │                                          │             │
│         │ (based on metric filter)                 │ invokes     │
│         ▼                                          ▼             │
│  ┌──────────────┐                         ┌───────────────────┐  │
│  │  CloudWatch   │◀── FilterLogEvents ────│  Lambda Function  │  │
│  │  Log Group    │    (last 5 minutes)    │  LogsAlarm        │  │
│  └──────────────┘                         └────────┬──────────┘  │
│                                                    │             │
│                                                    │ sns:Publish │
│                                                    ▼             │
│                                            ┌───────────────────┐ │
│                                            │  SNS Topic        │ │
│                                            │  (alarm action)   │ │
│                                            └───────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### Lambda Function Flow

1. Receives a **CloudWatch Alarm State Change** event from EventBridge.
2. Calls `cloudwatch:DescribeAlarms` to retrieve the alarm's SNS topic targets.
3. Iterates the alarm's metrics; for each custom-namespace metric (not `AWS/*`), calls `logs:DescribeMetricFilters` to find the associated metric filter.
4. Matches metric dimensions to filter transformations to ensure the correct filter.
5. Calls `logs:FilterLogEvents` on the matched Log Group for the last 5 minutes (up to 50 events).
6. Publishes the collected log samples to each of the alarm's SNS topics via `sns:Publish`.

### Resources Created (per account/region)

| Resource | Name Pattern | Purpose |
|---|---|---|
| IAM Role | `{PROJECT}-{ENV}-LogsAlarm-role` | Lambda execution role with least-privilege permissions |
| IAM Policies | `*-logs`, `*-cloudwatch`, `*-sns` | Separate policies for log writing, CW/Logs read, SNS publish |
| CloudWatch Log Group | `/aws/lambda/{PROJECT}-{ENV}-LogsAlarm` | Lambda's own log output (configurable retention) |
| Lambda Function | `{PROJECT}-{ENV}-LogsAlarm` | Python 3.13, arm64, 128 MB, 30s timeout |
| EventBridge Rule | `{PROJECT}-{ENV}-handleLogsAlarm` | Captures all `CloudWatch Alarm State Change` events where state = `ALARM` |
| Lambda Permission | `AllowEventBridgeInvoke` | Allows EventBridge to invoke the Lambda |

## Project Structure

```
logalarms/
├── terragrunt.hcl                                  # Root config: remote state, provider generation
├── _envcommon/
│   └── logsalarm.hcl                               # Shared component config (module source, common inputs)
├── modules/
│   └── logsalarm/
│       ├── main.tf                                  # All AWS resources (IAM, Lambda, EventBridge, LogGroup)
│       ├── variables.tf                             # Module input variables
│       └── outputs.tf                               # Module outputs
├── envs/
│   ├── systest/                                     # System test environment
│   │   ├── env.hcl                                  # Environment variables (single account)
│   │   └── eu-west-1/
│   │       └── logsalarm/
│   │           └── terragrunt.hcl                   # Leaf deployment
│   └── prodire/                                     # Production Ireland environment
│       ├── env.hcl                                  # Environment variables (multi-account, OU targets)
│       ├── eu-west-1/
│       │   └── logsalarm/
│       │       └── terragrunt.hcl                   # Leaf deployment
│       └── af-south-1/
│           └── logsalarm/
│               └── terragrunt.hcl                   # Leaf deployment
├── scripts/
│   └── generate_account_dirs.sh                     # Discovers OU accounts, scaffolds per-account dirs
├── src/
│   └── lambda_function.py                           # Lambda source code
└── .gitignore
```

### How the Directory Hierarchy Works

The Terragrunt configuration uses a **directory-as-config** pattern where environment, region, and (optionally) account ID are derived from the filesystem path:

```
envs/<environment>/<region>/logsalarm/                          # Single-account
envs/<environment>/<region>/<account_id>/logsalarm/             # Multi-account
```

- **Root `terragrunt.hcl`** -- Parses the directory path via regex to extract `environment` and `region`. Generates the AWS provider (with `assume_role` into the target account), the S3/DynamoDB remote state backend, and provider version constraints.
- **`env.hcl`** -- Per-environment variables: `project`, `service`, `environment`, `account_id`, `log_retention_days`. Located in `envs/<environment>/`.
- **`account.hcl`** (optional) -- Per-account override for `account_id`. Located in `envs/<environment>/<region>/<account_id>/`. If present, the root `terragrunt.hcl` prefers this over the `env.hcl` default.
- **`_envcommon/logsalarm.hcl`** -- Shared component config that points to the Terraform module source and passes common inputs (Lambda source path, log retention).
- **Leaf `terragrunt.hcl`** -- Minimal file that includes the root and envcommon configs. This is where `terragrunt plan/apply` is run.

## Prerequisites

- **Terraform/OpenTofu** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI v2** (for the account discovery script)
- **IAM execution role** in each target account: `arn:aws:iam::<account_id>:role/<project>-terraform-execution` (configurable in the root `terragrunt.hcl`)
- **S3 bucket** for Terraform state: `<project>-<environment>-tfstate-<account_id>` (auto-created by Terragrunt if `remote_state.config.skip_bucket_creation` is not set)
- **DynamoDB table** for state locking: `<project>-<environment>-tfstate-lock`

## Configuration

### Environment Variables (`env.hcl`)

| Variable | Type | Description |
|---|---|---|
| `project` | `string` | Project identifier (e.g. `devops`) |
| `service` | `string` | Service name (e.g. `logsalarm`) |
| `environment` | `string` | Environment name (e.g. `systest`, `prodire`) |
| `account_id` | `string` | Default AWS account ID for this environment |
| `log_retention_days` | `number` | CloudWatch Log Group retention in days |
| `target_ou_ids` | `list(string)` | (prodire only) AWS Organizations OU IDs to deploy into |
| `target_regions` | `list(string)` | (prodire only) AWS regions to deploy into |

### Module Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `project` | `string` | -- | Project identifier |
| `environment` | `string` | -- | Deployment environment |
| `service` | `string` | `logsalarm` | Service name |
| `aws_region` | `string` | -- | AWS region |
| `lambda_runtime` | `string` | `python3.13` | Lambda runtime |
| `lambda_memory_size` | `number` | `128` | Lambda memory (MB) |
| `lambda_timeout` | `number` | `30` | Lambda timeout (seconds) |
| `lambda_architectures` | `list(string)` | `["arm64"]` | Lambda CPU architecture |
| `log_retention_days` | `number` | `30` | Log Group retention (days) |
| `lambda_source_path` | `string` | -- | Path to `lambda_function.py` |
| `tags` | `map(string)` | `{}` | Additional resource tags |

### Module Outputs

| Output | Description |
|---|---|
| `lambda_function_arn` | ARN of the LogsAlarm Lambda function |
| `lambda_function_name` | Name of the LogsAlarm Lambda function |
| `lambda_role_arn` | ARN of the Lambda execution role |
| `eventbridge_rule_arn` | ARN of the EventBridge rule |
| `log_group_name` | Name of the Lambda CloudWatch Log Group |

## Deployment

### Single Environment / Region

```bash
# Plan
cd envs/systest/eu-west-1/logsalarm
terragrunt plan

# Apply
terragrunt apply
```

### All Regions in an Environment

```bash
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply
```

### Multi-Account Deployment (OU-based)

For production environments targeting multiple AWS accounts across OUs, use the account discovery script to generate per-account directories, then deploy with `run-all`:

```bash
# 1. Generate account directories from OU membership
./scripts/generate_account_dirs.sh prodire

# 2. Review what was created
find envs/prodire -name terragrunt.hcl

# 3. Plan all accounts and regions
cd envs/prodire
terragrunt run-all plan

# 4. Apply
terragrunt run-all apply
```

The script queries AWS Organizations for all active accounts in the configured OUs and creates:

```
envs/prodire/<region>/<account_id>/account.hcl          # Account-specific variables
envs/prodire/<region>/<account_id>/logsalarm/terragrunt.hcl  # Leaf deployment config
```

#### Generated Directory Layout (example)

After running `generate_account_dirs.sh prodire` with 3 accounts across 2 regions:

```
envs/prodire/
├── env.hcl
├── eu-west-1/
│   ├── 111111111111/
│   │   ├── account.hcl
│   │   └── logsalarm/terragrunt.hcl
│   ├── 222222222222/
│   │   ├── account.hcl
│   │   └── logsalarm/terragrunt.hcl
│   └── 333333333333/
│       ├── account.hcl
│       └── logsalarm/terragrunt.hcl
├── af-south-1/
│   ├── 111111111111/
│   │   ├── account.hcl
│   │   └── logsalarm/terragrunt.hcl
│   ├── ...
```

### Deploying a Single Account

```bash
cd envs/prodire/eu-west-1/111111111111/logsalarm
terragrunt plan
terragrunt apply
```

### Destroying Resources

```bash
# Single deployment
cd envs/systest/eu-west-1/logsalarm
terragrunt destroy

# All deployments in an environment
cd envs/prodire
terragrunt run-all destroy
```

## Remote State

State is stored per-account and per-region in S3 with DynamoDB locking:

| Config | Value |
|---|---|
| **Bucket** | `<project>-<environment>-tfstate-<account_id>` |
| **Key** | `<service>/<region>/terraform.tfstate` |
| **Region** | Same as the deployment region |
| **Encryption** | Enabled (AES-256) |
| **Versioning** | Enabled |
| **Lock Table** | `<project>-<environment>-tfstate-lock` |

## IAM Permissions

The Lambda function's IAM role has three inline policies with the minimum permissions required:

**`*-logs`** -- Write to its own CloudWatch Log Group:
- `logs:CreateLogStream`
- `logs:PutLogEvents`

**`*-cloudwatch`** -- Read alarm and log filter metadata:
- `cloudwatch:DescribeAlarms`
- `logs:DescribeMetricFilters`
- `logs:FilterLogEvents`

**`*-sns`** -- Publish enriched notifications:
- `sns:Publish`

The Terragrunt-generated provider assumes a role in each target account:
```
arn:aws:iam::<account_id>:role/<project>-terraform-execution
```

This role must exist in each target account and have permissions to create/manage the resources listed above. Adjust the role name in `terragrunt.hcl` if your naming convention differs.

## Adding a New Environment

1. Create the environment directory and `env.hcl`:

```bash
mkdir -p envs/staging/eu-west-1/logsalarm
```

```hcl
# envs/staging/env.hcl
locals {
  project            = "devops"
  service            = "logsalarm"
  environment        = "staging"
  account_id         = "444444444444"
  log_retention_days = 14
}
```

2. Create the leaf `terragrunt.hcl`:

```hcl
# envs/staging/eu-west-1/logsalarm/terragrunt.hcl
include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/logsalarm.hcl"
  expose = true
}
```

3. Deploy:

```bash
cd envs/staging/eu-west-1/logsalarm
terragrunt plan
terragrunt apply
```

## Adding a New Region

Create the region directory under the environment with a leaf `terragrunt.hcl`:

```bash
mkdir -p envs/prodire/us-east-1/logsalarm
```

Copy or create a `terragrunt.hcl` identical to the existing region leaves (the region is automatically parsed from the directory path).

## Porting Notes

This project was ported from an Ansible + CloudFormation deployment. Key changes:

| Aspect | Original (Ansible + CFN) | Current (Terragrunt + Terraform) |
|---|---|---|
| Infrastructure definition | CloudFormation JSON template | Native Terraform resources (HCL) |
| Multi-account targeting | CloudFormation StackSets with OU targeting | Terragrunt assume-role per account, directory per account |
| Multi-region targeting | StackSet instances per region | Terragrunt directory per region |
| Deployment orchestration | Ansible playbook + Jenkins | `terragrunt run-all plan/apply` |
| Lambda packaging | Ansible `zip` + `s3_object` upload | `archive_file` data source, inline `filename` upload |
| State management | CloudFormation stack state | S3 + DynamoDB per account/region |
| OU account discovery | Automatic (StackSet) | `scripts/generate_account_dirs.sh` |
| Lambda invocation source | `sns.amazonaws.com` (incorrect) | `events.amazonaws.com` (correct) |
| Python source bugs | ~16 syntax/logic errors | All fixed |
