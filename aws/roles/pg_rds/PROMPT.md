# Reusable Prompt: Generate a Terraform/Terragrunt Role

Use this prompt as a template when asking an AI assistant to scaffold a new AWS
infrastructure role in this project. Replace the placeholder sections in
`[BRACKETS]` with the specifics of the resource you want to deploy.

---

## The Prompt

```
I need Terraform (with Terragrunt) to deploy [RESOURCE DESCRIPTION, e.g. "an
ElastiCache Redis cluster", "an S3 bucket with replication", "an ECS Fargate
service"] in AWS. Follow the exact project conventions described below. The code
must be deployable across multiple environments (dev, staging, prod).

### Role Name

Use `[ROLE_NAME]` as the role identifier (snake_case).

### Directory Layout

Create the following structure under `aws/roles/[ROLE_NAME]/`:

```
[ROLE_NAME]/
├── terragrunt.hcl                                    # Root config
├── _envcommon/
│   └── [ROLE_NAME].hcl                               # Shared module source + default inputs
├── modules/[ROLE_NAME]/                              # Terraform module
│   ├── versions.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── main.tf
│   ├── security.tf                                   # If networking/SG resources needed
│   ├── monitoring.tf                                 # If CloudWatch alarms apply
│   └── outputs.tf
├── envs/
│   ├── dev/
│   │   ├── env.hcl
│   │   └── eu-west-1/[ROLE_NAME]/terragrunt.hcl
│   ├── staging/
│   │   ├── env.hcl
│   │   └── eu-west-1/[ROLE_NAME]/terragrunt.hcl
│   └── prod/
│       ├── env.hcl
│       └── eu-west-1/[ROLE_NAME]/terragrunt.hcl
└── README.md
```

### Terraform Module Conventions (`modules/[ROLE_NAME]/`)

**versions.tf:**
- `required_version = ">= 1.5.0"`
- Only declare providers actually used by the module (e.g. `hashicorp/aws >= 5.0`)

**variables.tf:**
- Group variables using banner comments:
  ```hcl
  ###############################################################################
  # Section Name
  ###############################################################################
  ```
- Always start with a "General" section containing: `project` (validated
  lowercase alphanumeric + hyphens), `environment` (validated enum: dev,
  staging, prod, uat, qa, sandbox), `service` (with a sensible default), `tags`
  (map(string), default {}).
- Include a "Networking" section when VPC resources are involved.
- Every variable must have `description` and `type`. Provide `default` wherever
  a sensible default exists.
- Use `validation {}` blocks liberally: regex for string formats, `contains()`
  for enums, range checks for numbers, `alltrue()` for list elements.
- End with a "Custom Identifier" section: `identifier_override` (string,
  default "").
- Make as many resource-specific options customizable as possible. Expose every
  meaningful AWS resource argument as a variable with a best-practice default.

**locals.tf:**
- Start with data sources outside the locals block:
  ```hcl
  data "aws_caller_identity" "current" {}
  data "aws_region" "current" {}
  ```
- Define naming: `name_prefix = "${var.project}-${var.environment}-${var.service}"`,
  `identifier` with override support.
- Derive computed values from inputs (e.g. engine family from version string).
- Use empty-string-to-null coercion for optional ARN/ID variables:
  `var.kms_key_id != "" ? var.kms_key_id : null`
- Define `default_tags` map (Project, Environment, Service, ManagedBy=terraform),
  then `tags = merge(local.default_tags, var.tags)`.
- Include best-practice default configuration for the resource (merged with
  user-supplied overrides using concat + contains exclusion).

**main.tf:**
- Name singleton resources `"this"`. Name collections descriptively.
- Use `lifecycle { create_before_destroy = true }` on configuration objects
  (parameter groups, security groups, etc.).
- Use `lifecycle { ignore_changes = [...] }` where timestamp or computed values
  cause perpetual diffs.
- Use `dynamic` blocks for optional features.
- Use explicit `depends_on` for ordering when implicit dependency is insufficient
  (e.g. log groups before instances).
- Tag every resource: `tags = merge(local.tags, { Name = "..." })`.

**security.tf** (when applicable):
- Create an `aws_security_group` with `create_before_destroy = true`.
- Use the modern `aws_vpc_security_group_ingress_rule` and
  `aws_vpc_security_group_egress_rule` resources (NOT inline rules or the
  deprecated `aws_security_group_rule`).
- Iterate CIDR blocks and security group IDs separately with `for_each = toset(...)`.
- Parameterize the port via a variable.

**monitoring.tf** (when applicable):
- Gate all alarms with `count = var.create_cloudwatch_alarms ? 1 : 0`.
- Create alarms for the key operational metrics of the resource.
- Use `treat_missing_data = "breaching"` for capacity/availability metrics and
  `"notBreaching"` for performance metrics.
- Expose each alarm threshold as a variable with a sensible default.
- Route all alarm/ok/insufficient_data actions to `var.alarm_sns_topic_arns`.
- Conditionally create IAM roles only when needed
  (`count = local.create_xxx ? 1 : 0`).

**outputs.tf:**
- Mirror the resource grouping from main.tf using banner comments.
- Output: id, arn, endpoint/address, and all operationally useful attributes.
- Include a convenience composite output (e.g. `connection_info` map).
- Every output must have a `description`.

### Terragrunt Conventions

**Root `terragrunt.hcl`:**
- Parse the directory path with regex to extract environment and region:
  `regex(".+/envs/(?P<env>[^/]+)/(?P<region>[^/]+)/.*", get_terragrunt_dir())`
- Load `env.hcl` via `read_terragrunt_config(find_in_parent_folders("env.hcl"))`.
- Optionally load `account.hcl` with `try()` for multi-account support.
- Configure S3 remote state with DynamoDB locking (bucket:
  `${project}-${environment}-tfstate-${account_id}`).
- Generate `provider.tf` with `assume_role` and `default_tags` (lowercase keys:
  project, environment, service, managed_by=terragrunt).
- Generate `versions.tf` with the same constraints as the module.
- Pass common inputs: `project`, `environment`, `service`.

**`_envcommon/[ROLE_NAME].hcl`:**
- Set `terraform.source = "${get_repo_root()}/aws/roles/[ROLE_NAME]/modules/[ROLE_NAME]"`.
- Read `env.hcl` and pass shared inputs. Use `try()` with `[]` fallback for
  optional list values.

**`envs/<env>/env.hcl`:**
- Pure `locals {}` block only -- no terraform or inputs blocks.
- Define: project, service, environment, account_id, networking, and all
  environment-specific tunables.
- Use placeholder values (`"vpc-xxxxxxxxxxxxxxxxx"`, `"000000000000"`) for
  IDs that must be replaced before deployment.

**Leaf `terragrunt.hcl`:**
- Two includes: `"root"` (find_in_parent_folders) and `"envcommon"` (with
  `expose = true`).
- Load env_vars via `read_terragrunt_config(find_in_parent_folders("env.hcl"))`.
- Pass environment-specific overrides from `env_vars.locals.*` in the inputs
  block, grouped with inline comments.

### Environment Differentiation

Apply this philosophy across dev/staging/prod:

| Aspect              | Dev                           | Staging                      | Prod                           |
|---------------------|-------------------------------|------------------------------|--------------------------------|
| **Sizing**          | Smallest viable               | Moderate / mirrors prod arch | Production-grade               |
| **HA/Redundancy**   | Disabled                      | Enabled                      | Enabled + read replicas        |
| **Backup**          | Minimal retention (1-3 days)  | Standard (7 days)            | Maximum (35 days)              |
| **Protection**      | No deletion protection        | Deletion protection on       | Deletion protection on         |
| **Final snapshot**  | Skipped                       | Required                     | Required                       |
| **Monitoring**      | Basic interval, alarms off    | Moderate interval, alarms on | Aggressive interval, alarms on |
| **Apply**           | Immediately                   | During maintenance window    | During maintenance window      |
| **Auto upgrades**   | Enabled                       | Enabled                      | Disabled (controlled manually) |

### Best Practices

- Enable encryption at rest and in transit by default.
- Use Secrets Manager for credentials (never plaintext in state).
- Default to private networking (not publicly accessible).
- Include comprehensive logging and monitoring out of the box.
- Pre-create CloudWatch log groups with configurable retention and KMS.
- Use `create_before_destroy` on mutable config objects.
- Expose granular customization -- users should be able to override anything.

### README.md

Include a comprehensive README with these sections (in order):
1. Title and one-liner description
2. Architecture ASCII diagram
3. Directory structure with inline comments
4. Prerequisites table + checklist
5. Quick start (configure, deploy, retrieve outputs)
6. Supported versions/variants table
7. Environment comparison table
8. Variables reference (tables grouped by section)
9. Best practices applied (Security, Observability, Reliability, Operations)
10. Default configuration parameters table with override examples
11. Outputs reference table
12. Operational runbooks (multi-region, restore, upgrades)
13. Resources created table
14. Terragrunt configuration layers diagram

### Additional Requirements

[ADD ANY RESOURCE-SPECIFIC REQUIREMENTS HERE, e.g.:
- "Support Redis cluster mode with configurable shard count"
- "Include cross-region replication"
- "Support both Fargate and EC2 launch types"
- etc.]
```

---

## Example: Using the Prompt for ElastiCache Redis

Replace the placeholders:
- `[RESOURCE DESCRIPTION]` → "an ElastiCache Redis cluster with replication"
- `[ROLE_NAME]` → `redis_cluster`
- `[Additional Requirements]` → "Support cluster mode enabled/disabled, automatic
  failover, configurable node types and replica counts per shard, snapshot
  support, and AUTH token via Secrets Manager"
