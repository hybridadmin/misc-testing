# AWS Health Events Notifications

Forwards [AWS Health events](https://docs.aws.amazon.com/health/latest/ug/aws-health-concepts-and-terms.html) to a Slack channel via an incoming webhook. Deployed as Terraform modules managed by Terragrunt across multiple AWS accounts and regions.

Ported from the CloudFormation StackSets project [`devops-utilities-notifications`](https://github.com/your-org/devops-utilities-notifications).

## Architecture

```
AWS Health Event
      |
      v
EventBridge Rule  (source: aws.health)
      |
      v
Lambda Function   (Python 3.13, posts to Slack webhook)
      |
      v
Slack Channel     (#owner-maintenance-notifications)
```

Each target account/region gets its own independent stack of these resources. The Lambda runs inside the target account so it receives that account's health events directly.

## AWS Resources Created (per account/region)

| Resource | Name Pattern | Description |
|---|---|---|
| `aws_iam_role` | `DEVOPS-PROD-AWS-HealthEvents-<region>` | Lambda execution role |
| `aws_iam_role_policy` | `...-logs` | Grants `logs:CreateLogStream`, `logs:PutLogEvents` to the Lambda log group |
| `aws_cloudwatch_log_group` | `/aws/lambda/DEVOPS-PROD-AWS-HealthEvents` | Lambda log group (30-day retention) |
| `aws_lambda_function` | `DEVOPS-PROD-AWS-HealthEvents` | Slack notifier Lambda |
| `aws_cloudwatch_event_rule` | `DEVOPS-PROD-AWS-Health-Events-Rule` | EventBridge rule matching all `aws.health` events |
| `aws_cloudwatch_event_target` | -- | Wires the rule to the Lambda |
| `aws_lambda_permission` | `AllowEventBridgeInvoke` | Allows EventBridge to invoke the Lambda |

## Project Structure

```
aws/notifications/
├── terragrunt.hcl                              # Root Terragrunt config
│                                                #   - S3 remote state
│                                                #   - AWS provider with assume_role
│                                                #   - Provider version constraints
│                                                #   - Common inputs
├── _envcommon/
│   └── notifications.hcl                        # Shared component config
│                                                #   - Module source path
│                                                #   - Slack & logging inputs
├── envs/
│   └── prod/
│       └── env.hcl                              # Environment variables
│                                                #   - target_ou_ids & target_regions
│                                                #   - Slack webhook URL & channel
│                                                #   - Log retention
├── modules/
│   └── notifications/
│       ├── main.tf                              # Terraform module (all resources)
│       ├── variables.tf                         # Input variables
│       └── outputs.tf                           # Output values
├── scripts/
│   └── generate_account_dirs.sh                 # Account discovery & dir generation
└── src/
    └── lambda_function.py                       # Lambda source code
```

### After running `generate_account_dirs.sh`

The script queries AWS Organizations and creates per-account directories:

```
envs/prod/
├── env.hcl
├── eu-west-1/
│   ├── 111111111111/
│   │   ├── account.hcl                          # account_id, account_name
│   │   └── notifications/
│   │       └── terragrunt.hcl                   # Leaf deployment config
│   ├── 222222222222/
│   │   ├── account.hcl
│   │   └── notifications/
│   │       └── terragrunt.hcl
│   └── ...
└── af-south-1/
    ├── 111111111111/
    │   ├── account.hcl
    │   └── notifications/
    │       └── terragrunt.hcl
    └── ...
```

## Terragrunt Configuration Hierarchy

Configuration is resolved through four layers:

```
Layer 1: terragrunt.hcl          (root)        Remote state, provider, common inputs
Layer 2: _envcommon/notifications.hcl           Module source, component-specific inputs
Layer 3: envs/<env>/env.hcl                     Environment-level variables (OUs, Slack, etc.)
Layer 4: envs/<env>/<region>/<acct>/            Leaf deployment point
         ├── account.hcl                        Per-account overrides (account_id, account_name)
         └── notifications/terragrunt.hcl       Includes layers 1 + 2
```

### How account_id is resolved

The root `terragrunt.hcl` uses a `try()` fallback pattern:

1. First attempts to load `account.hcl` from the parent of the leaf directory
2. If found (multi-account mode), uses that account's `account_id`
3. If not found (single-account mode), falls back to `account_id` in `env.hcl`

### How environment and region are resolved

Extracted from the filesystem path via regex -- no `region.hcl` files needed:

```hcl
parsed = regex(".+/envs/(?P<env>[^/]+)/(?P<region>[^/]+)/.*", get_terragrunt_dir())
```

## Remote State

Each account gets its own isolated state:

| Component | Pattern |
|---|---|
| S3 Bucket | `devops-<env>-tfstate-<account_id>` |
| State Key | `notifications/<region>/terraform.tfstate` |
| Lock Table | `devops-<env>-tfstate-lock` |

## Prerequisites

- **AWS CLI v2** -- configured with credentials that can call `organizations:ListAccountsForParent` (for the account discovery script)
- **Terraform / OpenTofu** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **jq** -- used by the account discovery script
- **IAM Role** -- a `devops-terraform-execution` role must exist in each target account, assumable from the deployment account

## Configuration

### Environment file (`envs/<env>/env.hcl`)

| Variable | Description | Example |
|---|---|---|
| `project` | Project identifier | `"devops"` |
| `service` | Service name | `"notifications"` |
| `environment` | Environment name | `"prod"` |
| `account_id` | Default/fallback account ID | `"000000000000"` |
| `log_retention_days` | CloudWatch log retention | `30` |
| `slack_channel` | Slack channel name | `"owner-maintenance-notifications"` |
| `slack_webhook_url` | Slack incoming webhook URL | `"https://hooks.slack.com/services/..."` |
| `target_ou_ids` | AWS Organizations OU IDs to deploy into | `["ou-xxxx-aaaaaaaa", ...]` |
| `target_regions` | AWS regions to deploy into | `["eu-west-1", "af-south-1"]` |

### Terraform Module Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `project` | `string` | -- | Project identifier |
| `environment` | `string` | -- | Deployment environment |
| `service` | `string` | `"notifications"` | Service name |
| `aws_region` | `string` | -- | AWS region |
| `slack_webhook_url` | `string` (sensitive) | -- | Slack webhook URL |
| `slack_channel` | `string` | -- | Slack channel name |
| `lambda_runtime` | `string` | `"python3.13"` | Lambda runtime |
| `lambda_memory_size` | `number` | `128` | Lambda memory (MB) |
| `lambda_timeout` | `number` | `60` | Lambda timeout (seconds) |
| `lambda_architectures` | `list(string)` | `["arm64"]` | Lambda architecture |
| `lambda_source_path` | `string` | -- | Path to Lambda source file |
| `log_retention_days` | `number` | `30` | Log retention (days) |
| `tags` | `map(string)` | `{}` | Additional resource tags |

### Module Outputs

| Output | Description |
|---|---|
| `lambda_function_arn` | ARN of the Health Events Lambda function |
| `lambda_function_name` | Name of the Health Events Lambda function |
| `lambda_role_arn` | ARN of the Lambda execution role |
| `eventbridge_rule_arn` | ARN of the EventBridge rule |
| `log_group_name` | Name of the Lambda CloudWatch Log Group |

## Usage

### 1. Generate account directories

Discovers all active accounts in the configured OUs and creates the Terragrunt directory structure:

```bash
./scripts/generate_account_dirs.sh prod
```

Output:

```
Environment: prod
Target OUs: ou-xxxx-aaaaaaaa ou-xxxx-bbbbbbbb ou-xxxx-cccccccc
Target Regions: eu-west-1 af-south-1

Querying accounts in OU: ou-xxxx-aaaaaaaa...
  Creating: envs/prod/eu-west-1/111111111111/notifications (my-prod-account)
  Creating: envs/prod/af-south-1/111111111111/notifications (my-prod-account)
...
Done. Created 12 new account/region directories.
```

The script is idempotent -- it skips directories that already exist.

### 2. Plan all accounts/regions

```bash
cd envs/prod
terragrunt run-all plan
```

### 3. Apply all accounts/regions

```bash
cd envs/prod
terragrunt run-all apply
```

### 4. Deploy a single account/region

```bash
cd envs/prod/eu-west-1/111111111111/notifications
terragrunt plan
terragrunt apply
```

### 5. Destroy a single account/region

```bash
cd envs/prod/eu-west-1/111111111111/notifications
terragrunt destroy
```

## Adding a New Environment

1. Create the environment directory and `env.hcl`:

```bash
mkdir -p envs/staging
```

```hcl
# envs/staging/env.hcl
locals {
  project            = "devops"
  service            = "notifications"
  environment        = "staging"
  account_id         = "000000000000"

  log_retention_days = 14

  slack_channel     = "staging-alerts"
  slack_webhook_url = "https://hooks.slack.com/services/..."

  target_ou_ids = [
    "ou-xxxx-staging01",
  ]

  target_regions = [
    "eu-west-1",
  ]
}
```

2. Generate account directories and deploy:

```bash
./scripts/generate_account_dirs.sh staging
cd envs/staging && terragrunt run-all apply
```

## Adding a New Region

Add the region to `target_regions` in `env.hcl`, then re-run the generate script:

```hcl
target_regions = [
  "eu-west-1",
  "af-south-1",
  "us-east-1",    # new region
]
```

```bash
./scripts/generate_account_dirs.sh prod
```

Existing directories are preserved; only new account/region combinations are created.

## Migration from CloudFormation StackSets

This project replaces the CloudFormation StackSets deployment (`stacksets/template.json` + `stacksets/deploy.sh`) with Terraform modules managed by Terragrunt. Key changes:

| Aspect | StackSets (before) | Terragrunt (after) |
|---|---|---|
| IaC tool | CloudFormation | Terraform / OpenTofu |
| Multi-account | StackSets with OU targeting | Directory-per-account with assume_role |
| Account discovery | Automatic (StackSets OU membership) | `generate_account_dirs.sh` queries Organizations API |
| Lambda code | Inline `ZipFile` in template | External `src/lambda_function.py` with `archive_file` |
| State | CloudFormation-managed | S3 + DynamoDB per account |
| Granularity | All-or-nothing per OU | Per account/region plan/apply |
| Secrets | CloudFormation parameters | `sensitive` Terraform variable (from `env.hcl`) |

## Secrets

The Slack webhook URL is currently stored in `env.hcl`. The Terraform variable is marked `sensitive = true` so it will not appear in plan output or state file values. For stronger protection, consider:

- Storing the webhook URL in AWS SSM Parameter Store or Secrets Manager
- Using a `data` source to fetch it at apply time
- Removing it from version control entirely

## Sample Health Event

The Lambda receives events in this format via EventBridge:

```json
{
  "version": "0",
  "id": "7bf73129-1428-4cd3-a780-95db273d1602",
  "detail-type": "AWS Health Event",
  "source": "aws.health",
  "account": "123456789012",
  "time": "2016-06-05T06:27:57Z",
  "region": "ap-southeast-2",
  "resources": [],
  "detail": {
    "eventArn": "arn:aws:health:ap-southeast-2::event/...",
    "service": "ELASTICLOADBALANCING",
    "eventTypeCode": "AWS_ELASTICLOADBALANCING_API_ISSUE",
    "eventTypeCategory": "issue",
    "startTime": "Sat, 04 Jun 2016 05:01:10 GMT",
    "endTime": "Sat, 04 Jun 2016 05:30:57 GMT",
    "eventDescription": [
      {
        "language": "en_US",
        "latestDescription": "A]description of the health event..."
      }
    ]
  }
}
```

The Lambda extracts `latestDescription` and `eventArn`, formats a Slack message with a link to the AWS Health Dashboard, and posts it to the configured channel.
