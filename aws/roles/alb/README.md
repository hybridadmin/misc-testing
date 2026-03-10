# ALB Terraform Module (Terragrunt Multi-Account Deployment)

Terraform module and Terragrunt wrapper for deploying an **Application Load Balancer** with optional **AWS WAFv2** protection across multiple AWS accounts and regions.

Ported from the CloudFormation template at `devops-reference-infrastructure/roles/alb/files/template.json`.

---

## Directory Structure

```
roles/alb/
├── terragrunt.hcl                          # Root: remote state, provider, versions
├── _envcommon/
│   └── alb.hcl                             # Shared component config (terraform source + input mapping)
├── modules/
│   └── alb/
│       ├── main.tf                         # ALB, SG, listeners, WAF resources
│       ├── variables.tf                    # All input variables
│       ├── outputs.tf                      # Exported values (ARNs, IDs, DNS)
│       └── versions.tf                     # Provider constraints (standalone use)
├── envs/
│   ├── systest/                            # Single-account environment
│   │   ├── env.hcl                         # Environment variables
│   │   └── eu-west-1/
│   │       └── alb/
│   │           └── terragrunt.hcl          # Leaf deployment point
│   └── prodire/                            # Multi-account environment
│       └── env.hcl                         # Env vars + target_ou_ids + target_regions
├── scripts/
│   └── generate_account_dirs.sh            # Auto-scaffolds per-account directories
├── .gitignore
└── README.md
```

---

## What Gets Created

The Terraform module provisions the following AWS resources:

| Resource | Description |
|---|---|
| `aws_security_group` | Allows inbound HTTP + HTTPS from configurable CIDR blocks |
| `aws_lb` | Application Load Balancer (internet-facing or internal) |
| `aws_lb_listener` (HTTPS) | TLS listener with default 404 fixed response |
| `aws_lb_listener` (HTTP) | Redirects all HTTP traffic to HTTPS (301) |
| `aws_wafv2_web_acl` | WAFv2 WebACL with 5 AWS Managed Rule Groups (conditional) |
| `aws_wafv2_web_acl_association` | Associates WAF with the ALB (conditional) |
| `aws_cloudwatch_log_group` x6 | One general WAF log group + one per rule set (conditional) |

### WAF Managed Rule Groups

When `enable_waf = true`, the following AWS Managed Rule Groups are attached:

| Rule Group | Priority | Description |
|---|---|---|
| AWSManagedRulesCommonRuleSet | 0 | OWASP Top 10 core rules |
| AWSManagedRulesKnownBadInputsRuleSet | 1 | Known bad inputs / exploits |
| AWSManagedRulesLinuxRuleSet | 3 | Linux-specific vulnerabilities |
| AWSManagedRulesAnonymousIpList | 5 | VPN, Tor, proxy detection |
| AWSManagedRulesBotControlRuleSet | 6 | Bot detection and management |

All rules default to **Count** mode (monitoring only). Set `waf_rule_action = "none"` to switch to **Enforce** (blocking) mode.

---

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI v2** (for `generate_account_dirs.sh`)
- An IAM role `<project>-terraform-execution` in each target account
- An S3 bucket `<project>-<environment>-tfstate-<account_id>` for remote state
- A DynamoDB table `<project>-<environment>-tfstate-lock` for state locking

---

## Configuration Layers

The configuration follows a four-layer hierarchy:

### Layer 1: Root `terragrunt.hcl`

Located at `roles/alb/terragrunt.hcl`. Handles:

- **Path parsing**: Extracts `environment` and `region` from the directory path
- **Remote state**: S3 backend with DynamoDB locking, bucket per account
- **Provider generation**: AWS provider with `assume_role` into target account
- **Version constraints**: Terraform >= 1.5.0, AWS provider ~> 5.0
- **Common inputs**: `project`, `environment`, `service`

### Layer 2: `_envcommon/alb.hcl`

Shared configuration included by every leaf `terragrunt.hcl`:

- Points `terraform.source` to `modules/alb/`
- Maps `env.hcl` locals to module input variables
- Uses `try()` for optional variables with sensible defaults

### Layer 3: `envs/<environment>/env.hcl`

Per-environment variables. Two patterns:

**Single-account** (e.g. `systest`):
```hcl
locals {
  project         = "myproject"
  service         = "alb"
  environment     = "systest"
  account_id      = "123456789012"
  vpc_id          = "vpc-abc123"
  subnet_ids      = ["subnet-aaa", "subnet-bbb"]
  certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/..."
  enable_waf      = false
}
```

**Multi-account** (e.g. `prodire`) -- adds `target_ou_ids` and `target_regions`:
```hcl
locals {
  # ... same as above, plus:
  target_ou_ids  = ["ou-xxxx-aaaaaaaa", "ou-xxxx-bbbbbbbb"]
  target_regions = ["eu-west-1", "af-south-1"]
}
```

### Layer 4: Leaf `terragrunt.hcl`

Minimal file at `envs/<env>/<region>/alb/terragrunt.hcl` (single-account) or `envs/<env>/<region>/<account_id>/alb/terragrunt.hcl` (multi-account). Contains two `include` blocks and optional per-deployment input overrides.

---

## Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `project` | string | - | Project identifier |
| `environment` | string | - | Deployment environment |
| `service` | string | - | Service name |
| `name` | string | `""` | ALB name override (defaults to `project-environment-service`) |
| `vpc_id` | string | - | VPC ID for the security group |
| `subnet_ids` | list(string) | - | Subnet IDs for ALB placement |
| `internal` | bool | `false` | `true` for internal ALB, `false` for internet-facing |
| `http_port` | number | `80` | HTTP listener port |
| `https_port` | number | `443` | HTTPS listener port |
| `certificate_arn` | string | - | ACM certificate ARN for HTTPS |
| `ssl_policy` | string | `ELBSecurityPolicy-TLS-1-2-Ext-2018-06` | TLS negotiation policy |
| `enable_access_logs` | bool | `true` | Enable S3 access logging |
| `access_logs_bucket` | string | `""` | S3 bucket for access logs |
| `access_logs_prefix` | string | `"alb"` | S3 key prefix for access logs |
| `ingress_cidr_blocks` | list(string) | `["0.0.0.0/0"]` | CIDR blocks allowed to reach ALB |
| `enable_waf` | bool | `false` | Attach WAFv2 WebACL |
| `waf_rule_action` | string | `"count"` | `"count"` (monitor) or `"none"` (enforce) |
| `log_retention_days` | number | `180` | CloudWatch log retention for WAF log groups |
| `tags` | map(string) | `{}` | Additional tags for all resources |

---

## Outputs

| Output | Description |
|---|---|
| `alb_id` | ID of the Application Load Balancer |
| `alb_arn` | ARN of the Application Load Balancer |
| `alb_dns_name` | DNS name of the ALB |
| `alb_zone_id` | Canonical hosted zone ID (for Route 53 alias records) |
| `https_listener_arn` | ARN of the HTTPS listener (attach listener rules here) |
| `http_listener_arn` | ARN of the HTTP listener |
| `security_group_id` | ID of the ALB security group |
| `waf_web_acl_arn` | ARN of the WAFv2 WebACL (empty if WAF disabled) |
| `waf_web_acl_id` | ID of the WAFv2 WebACL (empty if WAF disabled) |

---

## Deployment

### Single-Account Environment (systest)

```bash
# Plan
cd envs/systest/eu-west-1/alb
terragrunt plan

# Apply
terragrunt apply
```

### Multi-Account Environment (prodire)

#### Step 1: Generate per-account directories

The `generate_account_dirs.sh` script queries AWS Organizations to discover active accounts in the target OUs and scaffolds the directory structure:

```bash
# Requires AWS CLI credentials with organizations:ListAccountsForParent permission
./scripts/generate_account_dirs.sh prodire
```

This creates the following structure for each discovered account:

```
envs/prodire/
  eu-west-1/
    111111111111/
      account.hcl           # account_id + account_name
      alb/
        terragrunt.hcl      # leaf deployment config
    222222222222/
      account.hcl
      alb/
        terragrunt.hcl
  af-south-1/
    111111111111/
      account.hcl
      alb/
        terragrunt.hcl
    ...
```

#### Step 2: Customise per-account inputs

Edit each generated `alb/terragrunt.hcl` to supply account-specific values such as `subnet_ids`, `certificate_arn`, and `access_logs_bucket` in the `inputs` block.

#### Step 3: Deploy

```bash
# Plan all accounts/regions at once
cd envs/prodire
terragrunt run-all plan

# Apply all
terragrunt run-all apply

# Or deploy a single account/region
cd envs/prodire/eu-west-1/111111111111/alb
terragrunt plan
terragrunt apply
```

---

## Remote State

State is stored per-account in S3:

| Setting | Value |
|---|---|
| **Bucket** | `<project>-<environment>-tfstate-<account_id>` |
| **Key** | `<service>/<region>/terraform.tfstate` |
| **Lock Table** | `<project>-<environment>-tfstate-lock` |
| **Encryption** | Enabled (AES-256) |
| **Versioning** | Enabled |

---

## CloudFormation to Terraform Mapping

| CloudFormation Resource | Terraform Resource |
|---|---|
| `AWS::EC2::SecurityGroup` | `aws_security_group.alb` + individual ingress/egress rules |
| `AWS::ElasticLoadBalancingV2::LoadBalancer` | `aws_lb.this` |
| `AWS::ElasticLoadBalancingV2::Listener` (HTTPS) | `aws_lb_listener.https` |
| `AWS::ElasticLoadBalancingV2::Listener` (HTTP) | `aws_lb_listener.http` |
| `AWS::WAFv2::WebACL` | `aws_wafv2_web_acl.this[0]` |
| `AWS::WAFv2::WebACLAssociation` | `aws_wafv2_web_acl_association.this[0]` |
| `AWS::Logs::LogGroup` (x6) | `aws_cloudwatch_log_group.waf[0]` + `aws_cloudwatch_log_group.waf_rules["..."]` |

### Notable Changes from the CloudFormation Template

1. **Subnet handling**: The CFn template used nested `Fn::If` conditions to select 2 vs 3 subnets and public vs private. The Terraform module accepts a `subnet_ids` list directly -- pass the appropriate subnets for your use case.
2. **Security group**: Uses individual `aws_vpc_security_group_ingress_rule` / `egress_rule` resources instead of inline rules (AWS best practice). Adds an explicit egress rule (all outbound allowed).
3. **WAF rules**: Uses `dynamic` blocks with `for_each` over a local list instead of repeating each rule group individually. The `waf_rule_action` variable controls count vs enforce mode for all rules at once.
4. **Cross-stack references**: CFn `Fn::ImportValue` references (VPC, subnets, logs bucket) are replaced by explicit Terraform variables. The calling Terragrunt config supplies these values from `env.hcl`.
5. **Log group deletion policy**: CFn `DeletionPolicy: Retain` is not replicated. Terraform manages the full lifecycle. To retain log groups on destroy, use `lifecycle { prevent_destroy = true }` or handle via the AWS console.

---

## Adding a New Environment

1. Create `envs/<new_env>/env.hcl` with environment-specific values
2. For single-account: create `envs/<new_env>/<region>/alb/terragrunt.hcl`
3. For multi-account: add `target_ou_ids` and `target_regions` to `env.hcl`, then run `./scripts/generate_account_dirs.sh <new_env>`

---

## Adding a New Region to an Existing Environment

**Single-account**: Create `envs/<env>/<new_region>/alb/terragrunt.hcl` (copy from an existing region).

**Multi-account**: Add the region to `target_regions` in `env.hcl` and re-run `./scripts/generate_account_dirs.sh <env>`. The script is idempotent -- existing directories are skipped.
