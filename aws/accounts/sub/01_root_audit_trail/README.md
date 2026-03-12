# Root Console Sign-In Audit Trail

Terraform/Terragrunt module for monitoring AWS root user console sign-in activity across multiple AWS accounts and regions. Ported from the CloudFormation template `ROOT-AWS-Console-Sign-In-via-CloudTrail`.

## Overview

When an AWS root user signs in to the console, CloudTrail generates a sign-in event. This module deploys an EventBridge rule that matches those events and routes them to an SNS topic, which in turn emails the configured recipients.

### Resources Created (per account/region)

| Resource | Purpose |
|----------|---------|
| `aws_sns_topic` | Notification target for root sign-in events |
| `aws_sns_topic_policy` | Allows EventBridge to publish to the topic |
| `aws_sns_topic_subscription` | Email subscription(s) for alert recipients |
| `aws_cloudwatch_event_rule` | Matches `AWS Console Sign In via CloudTrail` events where `userIdentity.type == Root` |
| `aws_cloudwatch_event_target` | Routes matched events to the SNS topic |

### CloudFormation to Terraform Mapping

| CloudFormation Resource | Terraform Resource |
|-------------------------|-------------------|
| `AWS::SNS::Topic` (RootActivitySNSTopic) | `aws_sns_topic.root_activity` + `aws_sns_topic_subscription.email` |
| `AWS::SNS::TopicPolicy` (RootPolicyDocument) | `aws_sns_topic_policy.root_activity` |
| `AWS::Events::Rule` (EventsRule) | `aws_cloudwatch_event_rule.root_activity` + `aws_cloudwatch_event_target.sns` |

## Project Structure

```
master/
├── terragrunt.hcl                          # Root Terragrunt config (remote state, provider, versions)
├── _envcommon/
│   └── root_audit_trail.hcl                # Shared component config (module source, common inputs)
├── modules/
│   └── root_audit_trail/
│       ├── main.tf                         # Terraform resources (SNS, EventBridge)
│       ├── variables.tf                    # Module input variables
│       └── outputs.tf                      # Module outputs
├── envs/
│   ├── systest/                            # Single-account test environment
│   │   ├── env.hcl                         # Environment variables
│   │   └── eu-west-1/
│   │       └── root_audit_trail/
│   │           └── terragrunt.hcl          # Leaf deployment config
│   └── prodire/                            # Multi-account production environment
│       ├── env.hcl                         # Environment variables (includes target OUs & regions)
│       ├── eu-west-1/
│       │   └── root_audit_trail/
│       │       └── terragrunt.hcl          # Leaf deployment config
│       └── af-south-1/
│           └── root_audit_trail/
│               └── terragrunt.hcl          # Leaf deployment config
├── scripts/
│   └── generate_account_dirs.sh            # OU account discovery & directory scaffolding
├── .gitignore
└── README.md
```

### Multi-Account Directory Structure (after running generate_account_dirs.sh)

For multi-account environments, the script creates per-account directories:

```
envs/prodire/
├── env.hcl
├── eu-west-1/
│   ├── 111111111111/
│   │   ├── account.hcl                     # Account-specific overrides
│   │   └── root_audit_trail/
│   │       └── terragrunt.hcl              # Auto-generated leaf config
│   ├── 222222222222/
│   │   ├── account.hcl
│   │   └── root_audit_trail/
│   │       └── terragrunt.hcl
│   └── root_audit_trail/
│       └── terragrunt.hcl                  # Optional: default account deployment
└── af-south-1/
    ├── 111111111111/
    │   ├── account.hcl
    │   └── root_audit_trail/
    │       └── terragrunt.hcl
    └── ...
```

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI v2** (for the account directory generation script)
- **jq** (for the account directory generation script)
- AWS credentials with:
  - `sts:AssumeRole` permission to the terraform execution role in target accounts
  - `organizations:ListAccountsForParent` (for the scaffolding script only)

## Configuration

### Environment Variables (`env.hcl`)

Each environment directory contains an `env.hcl` file with the following locals:

| Variable | Type | Description |
|----------|------|-------------|
| `project` | string | Project identifier (used in naming and tags) |
| `service` | string | Service name, typically `root-audit-trail` |
| `environment` | string | Environment name (e.g. `systest`, `prodire`) |
| `account_id` | string | Default AWS account ID (overridden per-account in multi-account mode) |
| `email_addresses` | list(string) | Email addresses to receive root sign-in alerts |
| `target_ou_ids` | list(string) | *(multi-account only)* AWS Organizations OU IDs to deploy to |
| `target_regions` | list(string) | *(multi-account only)* AWS regions to deploy to |

### Module Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project` | string | - | Project identifier |
| `environment` | string | - | Deployment environment |
| `service` | string | `root-audit-trail` | Service name |
| `aws_region` | string | - | AWS region |
| `email_addresses` | list(string) | - | Email addresses for SNS subscriptions |
| `tags` | map(string) | `{}` | Additional tags for all resources |

### Module Outputs

| Output | Description |
|--------|-------------|
| `sns_topic_arn` | ARN of the root activity SNS topic |
| `sns_topic_name` | Name of the root activity SNS topic |
| `eventbridge_rule_arn` | ARN of the EventBridge rule |
| `eventbridge_rule_name` | Name of the EventBridge rule |

## Deployment

### 1. Configure the Environment

Edit the appropriate `envs/<environment>/env.hcl` file:

```hcl
locals {
  project     = "myproject"
  service     = "root-audit-trail"
  environment = "prodire"
  account_id  = "000000000000"

  email_addresses = [
    "security-team@example.com",
    "ops-team@example.com",
  ]

  target_ou_ids = [
    "ou-xxxx-aaaaaaaa",  # Production Accounts OU
    "ou-xxxx-bbbbbbbb",  # Development Accounts OU
  ]

  target_regions = [
    "eu-west-1",
    "af-south-1",
  ]
}
```

### 2. Generate Account Directories (Multi-Account)

For multi-account deployments, use the scaffolding script to discover accounts in the target OUs and create the directory structure:

```bash
./scripts/generate_account_dirs.sh prodire
```

This queries AWS Organizations for all active accounts in the configured OUs and creates the necessary `account.hcl` and leaf `terragrunt.hcl` files.

### 3. Deploy

#### Single Account (systest)

```bash
cd envs/systest/eu-west-1/root_audit_trail
terragrunt plan
terragrunt apply
```

#### All Accounts in an Environment

```bash
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply
```

#### Single Account/Region in Multi-Account Environment

```bash
cd envs/prodire/eu-west-1/111111111111/root_audit_trail
terragrunt plan
terragrunt apply
```

### 4. Confirm SNS Subscriptions

After deployment, each email address in `email_addresses` will receive a subscription confirmation email from AWS SNS. Recipients **must click the confirmation link** to start receiving root sign-in alerts.

## How It Works

1. A root user signs in to the AWS Console.
2. CloudTrail logs the sign-in event.
3. EventBridge receives the event and matches it against the rule:
   ```json
   {
     "detail-type": ["AWS Console Sign In via CloudTrail"],
     "detail": {
       "userIdentity": {
         "type": ["Root"]
       }
     }
   }
   ```
4. The matched event is published to the SNS topic.
5. SNS delivers the event details to all confirmed email subscribers.

## Architecture Patterns

This module follows the same layered Terragrunt architecture as the `logalarms` module:

- **Root `terragrunt.hcl`** -- Handles remote state (S3 + DynamoDB locking), provider generation with `assume_role`, and version constraints. Extracts environment and region from the directory path.
- **`_envcommon/root_audit_trail.hcl`** -- Shared component config that sets the Terraform module source and passes common inputs.
- **`envs/<env>/env.hcl`** -- Per-environment locals.
- **Leaf `terragrunt.hcl`** -- Minimal config with two `include` blocks (root + envcommon).
- **`account.hcl`** -- Per-account override (auto-generated by the scaffolding script for multi-account deployments).

### Remote State

State is stored in S3 with DynamoDB locking, using the naming convention:

- **Bucket:** `<project>-<environment>-tfstate-<account_id>`
- **Key:** `root-audit-trail/<region>/terraform.tfstate`
- **Lock table:** `<project>-<environment>-tfstate-lock`

### Provider

The provider assumes a role in the target account:

```
arn:aws:iam::<account_id>:role/<project>-terraform-execution
```

## Adding a New Environment

1. Create the environment directory:
   ```bash
   mkdir -p envs/<new-env>/<region>/root_audit_trail
   ```

2. Create `envs/<new-env>/env.hcl` with the required locals (see Configuration section).

3. Create the leaf `terragrunt.hcl`:
   ```hcl
   include "root" {
     path = find_in_parent_folders("terragrunt.hcl")
   }

   include "envcommon" {
     path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/root_audit_trail.hcl"
     expose = true
   }
   ```

4. For multi-account, add `target_ou_ids` and `target_regions` to `env.hcl` and run:
   ```bash
   ./scripts/generate_account_dirs.sh <new-env>
   ```

## Adding a New Region

For an existing environment, add the region to `target_regions` in `env.hcl`, then either:

- Run `generate_account_dirs.sh` again (it skips existing directories), or
- Manually create the region directory with a leaf `terragrunt.hcl`.

## Destroying Resources

```bash
# Single deployment
cd envs/<env>/<region>/root_audit_trail
terragrunt destroy

# All deployments in an environment
cd envs/<env>
terragrunt run-all destroy
```

## Origin

Ported from the AWS CloudFormation template:
- **Template:** `ROOT-AWS-Console-Sign-In-via-CloudTrail`
- **Original license:** MIT (Copyright 2019 Amazon.com, Inc.)
- **Source:** [AWS root user sign-in monitoring](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/monitor-and-notify-on-aws-account-root-user-activity.html)
